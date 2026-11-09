import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const root = process.cwd();
const generatedRoot = "/Users/king/.codex/generated_images/019f9b5b-c49c-7792-8d62-7a63b71b4d1a";
const assetsRoot = path.join(root, "OneWay", "Assets.xcassets");
const helper = "/Users/king/.codex/skills/.system/imagegen/scripts/remove_chroma_key.py";
const workingRoot = path.join(root, "tmp", "physical-icons");

const icons = [
  [
    "OneWayPhysicalQuantum",
    "call_aK5T3hyjo7GRG42onDTMSlm8.png",
  ],
  ["OneWayPhysicalCommunity", "call_jtbjfleeAYumbAxemZvJoKil.png"],
  ["OneWayPhysicalCalls", "call_1Iehp5faC6sE1y5NcNlKVnef.png"],
  ["OneWayPhysicalShops", "call_Iwk3F2BIwrYeUEW2XE0coKGj.png"],
  ["OneWayPhysicalCreate", "call_7G17BLDIfmiC5Rvcnpys2gWx.png"],
  ["OneWayPhysicalMessages", "call_IKZJntrJrwePJAvXqFYgdXf1.png"],
  ["OneWayPhysicalChirp", "call_5eWfYlhSsUMjcezUBDoTVQix.png"],
  ["OneWayPhysicalWallet", "call_F5sEjfx1XLlLggsbgxPYHDHY.png"],
  ["OneWayPhysicalSites", "call_MFd23ab0vKwYQfJ7uHPhNHtx.png"],
  ["OneWayPhysicalProduct", "call_f7jOYc7djhHwe0hSNwHIuhnt.png"],
  ["OneWayPhysicalSellerID", "call_AoVgaxsTXWo3i1wgkp9ngfXM.png"],
  ["OneWayPhysicalReceipt", "call_kfFQAeICWleynyN1FDFZXOXK.png"],
  ["OneWayPhysicalPlans", "call_1hjiz0gPvr3QXPXSioPRo1zc.png"],
  ["OneWayPhysicalSuccess", "call_FsNDGoZQkONdwvYpp1B3WJcF.png"],
  ["OneWayPhysicalCloud", "call_Vrvzq2HyAJuwElyh7qt7t1Ce.png"],
  ["OneWayPhysicalWorkspace", "call_yfwBilbVLPpbTgBNXBGJr9VX.png"],
  ["OneWayPhysicalSettings", "call_O8iUeQ9DADI9JYFcVhsohmXL.png"],
  ["OneWayPhysicalPrivacy", "call_EtbNhhlgI7XrNhv2BLvCzY0F.png"],
  ["OneWayPhysicalEmail", "call_rgm0GfHRaSfldeOTfiCBzKLi.png"],
  ["OneWayPhysicalVideo", "call_8EBg7H4uTQhaobSEqz281LsN.png"],
  ["OneWayPhysicalMicrophone", "call_qP2IqB8JrYWY60F6pAYxEiXi.png"],
  ["OneWayPhysicalSpeaker", "call_rkop7hCvJEiNefGCf6URHPg9.png"],
  ["OneWayPhysicalWarning", "call_vpn6kYAZMhJ7UaITyeK11h0S.png"],
  ["OneWayPhysicalError", "call_NpT7dJSSSMDyd5L3dKaFOrgk.png"],
];

fs.mkdirSync(workingRoot, { recursive: true });

for (const [assetName, sourceName, alreadyTransparent = false] of icons) {
  const source = path.isAbsolute(sourceName) ? sourceName : path.join(generatedRoot, sourceName);
  if (!fs.existsSync(source)) throw new Error(`Missing generated source: ${source}`);

  const transparent = path.join(workingRoot, `${assetName}-transparent.png`);
  fs.rmSync(transparent, { force: true });
  if (alreadyTransparent) {
    fs.copyFileSync(source, transparent);
  } else {
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
  }

  const imageSet = path.join(assetsRoot, `${assetName}.imageset`);
  fs.mkdirSync(imageSet, { recursive: true });
  const images = [
    { scale: "1x", pixels: 96, filename: `${assetName}.png` },
    { scale: "2x", pixels: 192, filename: `${assetName}@2x.png` },
    { scale: "3x", pixels: 288, filename: `${assetName}@3x.png` },
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

console.log(`Installed ${icons.length} physical icon image sets.`);
