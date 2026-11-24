#!/usr/bin/env python3
"""Builds Lumora's on-device AI models (runs on the macOS GitHub runner).

  Denoiser.mlpackage   DRUNet colour denoiser (KAIR, MIT) – input image [1,3,512,512] 0..1 sRGB + sigma [1]
  SkySegmenter.mlpackage  SegFormer-B0 ADE20K – input image [1,3,512,512] 0..1, output sky probability [1,1,128,128]
  ClipImage.mlpackage / ClipText.mlpackage   Apple MobileCLIP-S0 (Core ML export from apple/coreml-mobileclip)
  clip_vocab.txt       CLIP BPE merges (OpenAI CLIP, MIT)
"""
import gzip, os, shutil, sys, urllib.request
import numpy as np
import torch
import torch.nn as nn
import coremltools as ct

OUT = sys.argv[1] if len(sys.argv) > 1 else "Lumora/Models"
os.makedirs(OUT, exist_ok=True)
CACHE = os.path.expanduser("~/.lumora-model-cache")
os.makedirs(CACHE, exist_ok=True)


def fetch(url, name):
    path = os.path.join(CACHE, name)
    if not os.path.exists(path):
        print("downloading", url)
        urllib.request.urlretrieve(url, path)
    return path


# ---------------------------------------------------------------- DRUNet
class ResBlock(nn.Module):
    def __init__(self, c):
        super().__init__()
        self.res = nn.Sequential(nn.Conv2d(c, c, 3, 1, 1, bias=False), nn.ReLU(inplace=True), nn.Conv2d(c, c, 3, 1, 1, bias=False))

    def forward(self, x):
        return x + self.res(x)


class UNetRes(nn.Module):
    def __init__(self, in_nc=4, out_nc=3, nc=(64, 128, 256, 512), nb=4):
        super().__init__()
        self.m_head = nn.Conv2d(in_nc, nc[0], 3, 1, 1, bias=False)
        self.m_down1 = nn.Sequential(*[ResBlock(nc[0]) for _ in range(nb)], nn.Conv2d(nc[0], nc[1], 2, 2, 0, bias=False))
        self.m_down2 = nn.Sequential(*[ResBlock(nc[1]) for _ in range(nb)], nn.Conv2d(nc[1], nc[2], 2, 2, 0, bias=False))
        self.m_down3 = nn.Sequential(*[ResBlock(nc[2]) for _ in range(nb)], nn.Conv2d(nc[2], nc[3], 2, 2, 0, bias=False))
        self.m_body = nn.Sequential(*[ResBlock(nc[3]) for _ in range(nb)])
        self.m_up3 = nn.Sequential(nn.ConvTranspose2d(nc[3], nc[2], 2, 2, 0, bias=False), *[ResBlock(nc[2]) for _ in range(nb)])
        self.m_up2 = nn.Sequential(nn.ConvTranspose2d(nc[2], nc[1], 2, 2, 0, bias=False), *[ResBlock(nc[1]) for _ in range(nb)])
        self.m_up1 = nn.Sequential(nn.ConvTranspose2d(nc[1], nc[0], 2, 2, 0, bias=False), *[ResBlock(nc[0]) for _ in range(nb)])
        self.m_tail = nn.Conv2d(nc[0], out_nc, 3, 1, 1, bias=False)

    def forward(self, x0):
        x1 = self.m_head(x0)
        x2 = self.m_down1(x1)
        x3 = self.m_down2(x2)
        x4 = self.m_down3(x3)
        x = self.m_body(x4)
        x = self.m_up3(x + x4)
        x = self.m_up2(x + x3)
        x = self.m_up1(x + x2)
        return self.m_tail(x + x1)


class DenoiseWrapper(nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, image, sigma):
        noise = torch.ones_like(image[:, :1, :, :]) * sigma.view(1, 1, 1, 1)
        out = self.net(torch.cat([image, noise], dim=1))
        return torch.clamp(out, 0.0, 1.0)


def build_denoiser():
    dst = os.path.join(OUT, "Denoiser.mlpackage")
    if os.path.exists(dst):
        return
    w = fetch("https://github.com/cszn/KAIR/releases/download/v1.0/drunet_color.pth", "drunet_color.pth")
    net = UNetRes()
    sd = torch.load(w, map_location="cpu", weights_only=False)
    net.load_state_dict(sd, strict=True)
    model = DenoiseWrapper(net).eval()
    ex = (torch.rand(1, 3, 512, 512), torch.tensor([15.0 / 255.0]))
    with torch.no_grad():
        traced = torch.jit.trace(model, ex)
        # sanity check: denoising should reduce error on a noisy flat image
        clean = torch.full((1, 3, 512, 512), 0.5)
        noisy = clean + torch.randn_like(clean) * (15 / 255)
        den = model(noisy, torch.tensor([15 / 255]))
        print("DRUNet MSE noisy", float(((noisy - clean) ** 2).mean()), "denoised", float(((den - clean) ** 2).mean()))
    ml = ct.convert(traced, convert_to="mlprogram",
                    inputs=[ct.TensorType(name="image", shape=(1, 3, 512, 512), dtype=np.float32),
                            ct.TensorType(name="sigma", shape=(1,), dtype=np.float32)],
                    outputs=[ct.TensorType(name="output", dtype=np.float32)],
                    compute_precision=ct.precision.FLOAT16,
                    minimum_deployment_target=ct.target.iOS17)
    ml.short_description = "DRUNet colour denoiser (KAIR)"
    ml.save(dst)
    print("saved", dst)


# ---------------------------------------------------------------- Sky (SegFormer-B0 ADE20K)
class SkyWrapper(nn.Module):
    def __init__(self, seg):
        super().__init__()
        self.seg = seg
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

    def forward(self, image):
        logits = self.seg(pixel_values=(image - self.mean) / self.std, return_dict=False)[0]
        prob = torch.softmax(logits, dim=1)
        return prob[:, 2:3, :, :]  # ADE20K class 2 = sky


def build_sky():
    dst = os.path.join(OUT, "SkySegmenter.mlpackage")
    if os.path.exists(dst):
        return
    from transformers import SegformerForSemanticSegmentation
    seg = SegformerForSemanticSegmentation.from_pretrained("nvidia/segformer-b0-finetuned-ade-512-512", torchscript=True).eval()
    model = SkyWrapper(seg).eval()
    ex = torch.rand(1, 3, 512, 512)
    with torch.no_grad():
        traced = torch.jit.trace(model, ex, strict=False)
    ml = ct.convert(traced, convert_to="mlprogram",
                    inputs=[ct.TensorType(name="image", shape=(1, 3, 512, 512), dtype=np.float32)],
                    outputs=[ct.TensorType(name="sky", dtype=np.float32)],
                    compute_precision=ct.precision.FLOAT16,
                    minimum_deployment_target=ct.target.iOS17)
    ml.save(dst)
    print("saved", dst)


# ---------------------------------------------------------------- MobileCLIP
def build_clip():
    img_dst = os.path.join(OUT, "ClipImage.mlpackage")
    txt_dst = os.path.join(OUT, "ClipText.mlpackage")
    if not (os.path.exists(img_dst) and os.path.exists(txt_dst)):
        from huggingface_hub import snapshot_download
        p = snapshot_download("apple/coreml-mobileclip", allow_patterns=["mobileclip_s0_image.mlpackage/*", "mobileclip_s0_text.mlpackage/*"],
                              cache_dir=os.path.join(CACHE, "hf"))
        shutil.copytree(os.path.join(p, "mobileclip_s0_image.mlpackage"), img_dst, dirs_exist_ok=True)
        shutil.copytree(os.path.join(p, "mobileclip_s0_text.mlpackage"), txt_dst, dirs_exist_ok=True)
    for path in (img_dst, txt_dst):
        m = ct.models.MLModel(path, skip_model_load=True)
        spec = m.get_spec()
        print(path)
        for i in spec.description.input:
            print("  input ", i.name, i.type.WhichOneof("Type"), i.type)
        for o in spec.description.output:
            print("  output", o.name, o.type.WhichOneof("Type"))
    vocab_gz = fetch("https://raw.githubusercontent.com/openai/CLIP/main/clip/bpe_simple_vocab_16e6.txt.gz", "bpe_simple_vocab_16e6.txt.gz")
    with gzip.open(vocab_gz, "rt", encoding="utf-8") as f:
        lines = f.read().split("\n")
    # keep only the merges CLIP uses (header + 48894 merges)
    with open(os.path.join(OUT, "clip_vocab.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines[: 49152 - 256 - 2 + 1]))


if __name__ == "__main__":
    import traceback
    failed = []
    for fn in (build_denoiser, build_sky, build_clip):
        try:
            fn()
        except Exception:
            failed.append(fn.__name__)
            traceback.print_exc()
    print("models:", os.listdir(OUT))
    if failed:
        print("FAILED:", failed)
