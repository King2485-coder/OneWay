import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const root = process.cwd();
const generatedRoot = "/Users/king/.codex/generated_images/019f9b5b-c49c-7792-8d62-7a63b71b4d1a";
const assetsRoot = path.join(root, "OneWay", "Assets.xcassets");
const helper = "/Users/king/.codex/skills/.system/imagegen/scripts/remove_chroma_key.py";
const workingRoot = path.join(root, "tmp", "shops-reference-assets");

const assets = [
  ["OneWayShopsHeroShowcase", "call_Q3EC9LZcH8VgC3a2kbkhqI1v.png", 220],
  ["OneWayShopsCategoryHome", "call_TviMTbcXzMHdvciHk44yGD1a.png", 120],
  ["OneWayShopsCategoryJewelry", "call_w04hrL2T9BtPA7evDmqj8K0t.png", 120],
  ["OneWayShopsCategoryArt", "call_xFD2ADSaAzMIgzv9ONDZY6rQ.png", 120],
  ["OneWayShopsCategoryBeauty", "call_GI9dsWnjcbsbNTE6skuFxjq2.png", 120],
  ["OneWayShopsCategoryTech", "call_WHtfjvlzNJejNdR0dPwf4VKJ.png", 120],
  ["OneWayShopsProductMoonLamp", "call_uZkq9eYYBuZsGXkf23nZUTyW.png", 200],
  ["OneWayShopsProductAmethyst", "call_txCzW2m2NkygifJnTleOIR1d.png", 200],
  ["OneWayShopsCategoryClothing", "call_d4PYoRsusKkm5QPov40vTyWi.png", 120],
  ["OneWayShopsCategoryVintage", "call_GvoZeyhg2eepvrxphGFELI3O.png", 120],
  ["OneWayShopsProductMug", "call_ObV4to1LIjgSoDHUpWBbWDIK.png", 200],
  ["OneWayShopsProductBowl", "call_rOLK3cIJ93ihI2qURRgWNDEq.png", 200],
  ["OneWayShopsProductVase", "call_3q9wTlT563OsrUcykjBbd1S7.png", 200],
  ["OneWayShopsProductDiffuser", "call_BApa83X7MaOmRhAfvbmPgoSC.png", 200],
  ["OneWayShopsPhysicalFavorite", "call_YYxxhGOC3VDNKNrQdcg3afwI.png", 120],
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

console.log(`Installed ${assets.length} OneWay Shops reference asset sets.`);
