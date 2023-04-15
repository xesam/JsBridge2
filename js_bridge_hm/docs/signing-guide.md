# Harmony Signing Guide

This document records the signing-related issues we hit repeatedly in `js_bridge_hm`, the reasons behind them, and the working practice for local DevEco development and repository hygiene.

## Goal

Keep both of these true at the same time:

1. The repository stays safe and does not store local signing materials.
2. Developers can still build and install a signed HAP locally.

## Baseline Rule

The repository-tracked file:

- `js_bridge_hm/js-bridge-example/build-profile.json5`

must stay in a safe baseline:

- `signingConfigs: []`
- `products.default` does not bind a real `signingConfig`

With this baseline, the repository can only produce an unsigned HAP by default. That is expected.

## Repeated Problem

### Symptom

DevEco / `hdc` tries to install:

```text
entry-default-unsigned.hap
```

and the install fails with:

```text
error: no signature file
```

### Root Cause

One of these is true:

1. `signingConfigs.default` does not exist.
2. `products.default` is not bound to `signingConfig: "default"`.
3. The signing material exists only on one developer machine, but the repository is currently on the safe unsigned baseline.

The most common direct cause we hit was:

- DevEco had generated a local signing config before.
- Later we removed the binding to keep the repository safe.
- DevEco still built successfully, but only produced `entry-default-unsigned.hap`.
- Deployment then failed because the device requires a signed HAP.

## Local DevEco Practice

### When You Need to Run on a Device

Configure signing locally in DevEco Studio.

Required local state:

1. `build-profile.json5` contains a `signingConfigs.default`.
2. `products.default` contains:

```json
"signingConfig": "default"
```

3. The referenced files exist under your local `~/.ohos/config/`.

After that, DevEco should produce:

- `entry-default-signed.hap`

not only:

- `entry-default-unsigned.hap`

### Important

This local signing configuration is for your machine only. It must not be committed.

## Repository Hygiene

After local signing works, mark the file as local-only for normal day-to-day development:

```bash
git update-index --skip-worktree js_bridge_hm/js-bridge-example/build-profile.json5
```

You can verify the state with:

```bash
git ls-files -v js_bridge_hm/js-bridge-example/build-profile.json5
```

Expected output starts with:

```text
S
```

If you need Git to track the file normally again:

```bash
git update-index --no-skip-worktree js_bridge_hm/js-bridge-example/build-profile.json5
```

## CI / Release Practice

CI must not depend on a developer machine path like:

```text
~/.ohos/config/...
```

Recommended practice:

1. Store signing files and passwords in CI secrets or a private artifact store.
2. Generate the signing section dynamically during the pipeline.
3. Build the signed HAP.
4. Remove the injected files/config after the build.

Do not commit certificate paths, `.p12`, `.p7b`, or signing passwords into Git.

## Security Lessons Learned

We already hit this failure mode multiple times:

1. To make local install work, DevEco wrote local signing data into `build-profile.json5`.
2. That file was repo-tracked.
3. Local certificate paths and encrypted passwords were then pushed to Git history.

Latest tip may be clean, but that does not erase the old history.

### Required follow-up if this happens

Rotate the affected debug signing materials:

- certificate
- profile
- p12
- signing passwords

Cleaning only the latest commit is not enough.

## Fast Troubleshooting Checklist

When DevEco shows:

```text
error: no signature file
```

check in order:

1. Does `build-profile.json5` contain `signingConfigs.default` locally?
2. Does `products.default` contain `"signingConfig": "default"` locally?
3. Do the referenced signing files actually exist in `~/.ohos/config/`?
4. Did DevEco output `entry-default-signed.hap`?
5. Is `build-profile.json5` marked with `skip-worktree` after local setup?

## Commands We Actually Used

Local signed build:

```bash
cd js_bridge_hm/js-bridge-example
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
  /Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  assembleHap --mode module -p product=default --no-daemon
```

Verify outputs:

```bash
find entry/build/default/outputs/default -maxdepth 1 -name '*.hap'
```

Expected local result after signing is configured:

- `entry-default-signed.hap`
- `entry-default-unsigned.hap`
