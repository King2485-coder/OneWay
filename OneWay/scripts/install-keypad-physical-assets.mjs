import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const root = process.cwd();
const generatedRoot = "/Users/king/.codex/generated_images/019f9b5b-c49c-7792-8d62-7a63b71b4d1a";
const assetsRoot = path.join(root, "OneWay", "Assets.xcassets");
const helper = "/Users/king/.codex/skills/.system/imagegen/scripts/remove_chroma_key.py";
const workingRoot = path.join(root, "tmp", "keypad-physical-assets");

const assets = [
  ["OneWayPhysicalDialerDevice", "call_uRdJUglyCOkzaLWN1fuSOpBr.png", 220],
  ["OneWayPhysicalSearch", "call_y626UgBZHZCLvG7pBe023Kmu.png", 120],
  ["OneWayPhysicalFavoriteStar", "call_3hc5UrsYQwNHwLTrzYwDk1rW.png", 120],
  ["OneWayPhysicalRecents", "call_VZnzQwYxTvGjdxTznUwhVmRR.png", 120],
  ["OneWayPhysicalKeypad", "call_RDY3vQbEm4amYyjtBdLWRivb.png", 120],
  ["OneWayPhysicalVoicemail", "call_I1dkebOzwULj2Y3Kpjx1o18S.png", 120],
  ["OneWayPhysicalDeleteDigit", "call_rXHNqk6M2HxcgxrNpMAZqyIS.png", 120],
];

fs.mkdirSync(workingRoot, { recursive: true });

for (const [assetName, sourceName, pointPixels] of assets) {
  const source = path.join(generatedRoot, sourceName);
  if (!fs.existsSync(source)) throw new Error(`Missing generated source: ${source}`);

  const transparent = path.join(workingRoot, `${assetName}-transparent.png`);
  fs.rmSync(transparent, { force: true });
  execFileSync("python3", [
    helper,
    "--input", source,
    "--out", transparent,
    "--auto-key", "border",
    "--soft-matte",
    "--transparent-threshold", "12",
    "--opaque-threshold", "220",
    "--despill",
    "--edge-contract", "1",
  ], { stdio: "inherit" });

  const imageSet = path.join(assetsRoot, `${assetName}.imageset`);
  fs.mkdirSync(imageSet, { recursive: true });
  const images = [
    { scale: "1x", pixels: pointPixels, filename: `${assetName}.png` },
    { scale: "2x", pixels: pointPixels * 2, filename: `${assetName}@2x.png` },
    { scale: "3x", pixels: pointPixels * 3, filename: `${assetName}@3x.png` },
  ];

  for (const image of images) {
    const output = path.join(imageSet, image.filename);
    fs.copyFileSync(transparent, output);
    execFileSync("sips", ["-z", String(image.pixels), String(image.pixels), output], { stdio: "ignore" });
  }

  fs.writeFileSync(
    path.join(imageSet, "Contents.json"),
    JSON.stringify({
      images: images.map(({ filename, scale }) => ({ filename, idiom: "universal", scale })),
      info: { author: "xcode", version: 1 },
      properties: { "preserves-vector-representation": false },
    }, null, 2) + "\n"
  );
}

console.log(`Installed ${assets.length} OneWay Keypad physical asset sets.`);
