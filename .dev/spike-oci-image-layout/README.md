# Spike: OCI image layout → GHCR (ORAS)

Hands-on steps to build and push two OCI artifacts to [GitHub Container Registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry) using the [ORAS CLI](https://oras.land/docs/commands/oras_push). This spike validates layout and registry push only — **no** `infraweave.module.metadata` or `infraweave.project.metadata` layers.

**Normative product shape** (for later `oci-module` implementation): [`../oci-module/plan.md`](../oci-module/plan.md), [`../oci-module/exploration.md`](../oci-module/exploration.md).

| Image | Layers | Consumers |
|-------|--------|-----------|
| **1 — module-only** | One `archive/zip` | OpenTofu `tofu init` via `oci://` |
| **2 — runnable** | `archive/zip` + `application/vnd.infraweave.project.v1+zip` | OpenTofu (module zip only) + Infraweave runner (project layer) |

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| [ORAS](https://oras.land/docs/installation) ≥ 1.2 | Push / pull / inspect artifacts |
| `zip` | Build layer archives |
| [OpenTofu](https://opentofu.org/) | Validate `oci://` module consumption (image 1 and module layer of image 2) |
| GitHub account + PAT or `GITHUB_TOKEN` | Push to `ghcr.io` |

Install ORAS (macOS example):

```bash
brew install oras
oras version
```

### Authenticate to GHCR

Create a [classic PAT](https://github.com/settings/tokens) with `write:packages` (and `read:packages` for pull tests), or use `GITHUB_TOKEN` in CI.

```bash
export GHCR_USER="<github-username>"   # lowercase; for GITHUB_TOKEN in Actions, use github.actor
export GHCR_TOKEN="<pat-or-GITHUB_TOKEN>"

echo "$GHCR_TOKEN" | oras login ghcr.io -u "$GHCR_USER" --password-stdin
```

Pick a repository name (GHCR image path). Examples below use:

```text
ghcr.io/<owner>/infraweave-oci-spike
```

Replace `<owner>` with your GitHub user or org (lowercase).

---

## GitHub Actions (standalone repo)

This folder is meant to be copied into its own spike repository with `.github/workflows/spike.yml` at the repo root. The workflow is self-contained: it writes `module-src` / `project-src` via heredoc under `work/`, uses [`oras-project/setup-oras`](https://github.com/oras-project/setup-oras) and [`opentofu/setup-opentofu`](https://github.com/opentofu/setup-opentofu), pushes to `ghcr.io/${{ github.repository_owner }}/infraweave-oci-spike`, then pull + `tofu init` checks.

| Trigger | When |
|---------|------|
| `workflow_dispatch` | Manual run |
| `push` to `main` | Automatic on default branch |

Set `permissions.packages: write` (already in the workflow). Run from **Actions → Spike OCI image layout → Run workflow** after the repo exists on GitHub.

---

## Spike workspace

Committed fixtures live in this directory. Use it as `SPIKE_ROOT` and create `out/` for zips and pulled artifacts:

```bash
SPIKE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # this folder
mkdir -p "$SPIKE_ROOT/out"
cd "$SPIKE_ROOT"
```

---

## Source trees (committed fixtures)

### Module package (`module-src/`)

Provider-less module: prefixes `var.called-from-project` with `module-` and exposes `output.value`.

| File | Role |
|------|------|
| [`module-src/variables.tf`](module-src/variables.tf) | Input `input` |
| [`module-src/outputs.tf`](module-src/outputs.tf) | `value = "module-${…}"` |

With `input = "called-from-project"`, `value` is **`module-called-from-project`**.

### Root project (`project-src/`) — image 2 only

Calls the co-located OCI module as `module "module"` and re-exports `module.module.value`.

| File | Role |
|------|------|
| [`project-src/main.tofu`](project-src/main.tofu) | `module "module"` → `oci://ghcr.io/<owner>/infraweave-oci-spike?tag=runnable` |
| [`project-src/outputs.tf`](project-src/outputs.tf) | Root `output.value` |

Before pushing, replace `<owner>` in `project-src/main.tofu` with your GHCR namespace.

After the first push of image 2, you can pin the module `source` to a manifest digest instead of `tag=runnable`; re-zip and re-push if you change the project layer.

---

## Build zip layers

From `$SPIKE_ROOT`:

```bash
# Module package (required for both images)
(cd module-src && zip -r ../out/module-package.zip . -x '*.DS_Store')

# Root project (image 2 only)
(cd project-src && zip -r ../out/project-root.zip . -x '*.DS_Store')

# Sanity check: module .tf at archive root
unzip -l out/module-package.zip | head
unzip -l out/project-root.zip | head
```

OpenTofu expects the module zip to be a normal archive whose root is the module package root ([module packages](https://opentofu.org/docs/cli/oci_registries/module-package/)).

---

## Image 1 — minimum OpenTofu OCI module package

### Requirements (OpenTofu)

| Field | Value |
|-------|--------|
| Manifest | OCI Image Manifest (artifact) |
| `artifactType` | `application/vnd.opentofu.modulepkg` (exact) |
| Layers | **Exactly one** descriptor with `mediaType` **`archive/zip`** |

### Push with ORAS

```bash
REPO="ghcr.io/<owner>/infraweave-oci-spike"
TAG="module-only"

oras push \
  --artifact-type application/vnd.opentofu.modulepkg \
  "$REPO:$TAG" \
  out/module-package.zip:archive/zip
```

Optional: export the manifest for diffing with a future Rust builder:

```bash
oras push \
  --artifact-type application/vnd.opentofu.modulepkg \
  --export-manifest out/manifest-module-only.json \
  "$REPO:$TAG" \
  out/module-package.zip:archive/zip
```

### Inspect

```bash
oras manifest fetch "$REPO:$TAG" | jq .
# Expect:
#   .artifactType == "application/vnd.opentofu.modulepkg"
#   .layers | length == 1
#   .layers[0].mediaType == "archive/zip"
```

Pull blobs locally:

```bash
mkdir -p out/pulled-module-only
oras pull "$REPO:$TAG" -o out/pulled-module-only
```

### Verify with OpenTofu

Create a temporary root that consumes **only** the module artifact:

```bash
mkdir -p out/tofu-test-module-only
cat > out/tofu-test-module-only/main.tf <<'EOF'
module "example" {
  source = "oci://ghcr.io/<owner>/infraweave-oci-spike?tag=module-only"

  input = "from-external-root"
}

output "value" {
  value = module.example.value
}
EOF

cd out/tofu-test-module-only
tofu init
```

`init` should download the module from GHCR without error.

---

## Image 2 — module + Infraweave project layer

Same `artifactType` and the same **single** `archive/zip` module layer, plus one extension layer for the runner. **Metadata JSON layers are omitted** in this spike.

| Layer | `mediaType` | Role |
|-------|-------------|------|
| Module | `archive/zip` | OpenTofu module package (same zip as image 1) |
| Root project | `application/vnd.infraweave.project.v1+zip` | Workspace entry for Infraweave runner |

### Push with ORAS

ORAS accepts multiple `file:mediaType` pairs on one manifest ([oras push](https://oras.land/docs/commands/oras_push)):

```bash
REPO="ghcr.io/<owner>/infraweave-oci-spike"
TAG="runnable"

oras push \
  --artifact-type application/vnd.opentofu.modulepkg \
  --export-manifest out/manifest-runnable.json \
  "$REPO:$TAG" \
  out/module-package.zip:archive/zip \
  out/project-root.zip:application/vnd.infraweave.project.v1+zip
```

### Inspect

```bash
oras manifest fetch "$REPO:$TAG" | jq .
# Expect:
#   .artifactType == "application/vnd.opentofu.modulepkg"
#   .layers | length == 2
#   one layer mediaType == "archive/zip"
#   one layer mediaType == "application/vnd.infraweave.project.v1+zip"
```

Pull both layers:

```bash
mkdir -p out/pulled-runnable
oras pull "$REPO:$TAG" -o out/pulled-runnable
ls -la out/pulled-runnable
```

Runner POC (not part of this spike’s commands): select the project layer, extract, run `tofu` — see [`../oci-module-runner/plan.md`](../oci-module-runner/plan.md).

### Verify OpenTofu still accepts the artifact

OpenTofu uses **only** the `archive/zip` layer; extra layers must not break `oci://` module resolution ([exploration](../oci-module/exploration.md#two-layer-execution-model-module--root-project)).

Point a test root at the **same tag** as the runnable image (module-only consumption):

```bash
mkdir -p out/tofu-test-runnable-as-module
cat > out/tofu-test-runnable-as-module/main.tf <<'EOF'
module "example" {
  source = "oci://ghcr.io/<owner>/infraweave-oci-spike?tag=runnable"

  called-from-project = "from-external-root"
}

output "value" {
  value = module.example.value
}
EOF

cd out/tofu-test-runnable-as-module
tofu init
```

### Verify project layer (manual)

```bash
cd out/pulled-runnable
# ORAS names pulled files from descriptors; locate the project zip, then:
unzip -l '<project-archive>.zip'
# Expect main.tofu with module "module" { source = "oci://..." }
```

After `tofu apply` in the extracted project (with registry auth), root `output.value` should be **`module-called-from-project`**.

---

## Optional: local OCI layout before GHCR

Push to an on-disk [OCI image layout](https://github.com/opencontainers/image-spec/blob/main/image-layout.md) to inspect blobs without a registry:

```bash
LAYOUT="$SPIKE_ROOT/out/layout"

oras push \
  --oci-layout "$LAYOUT:module-only" \
  --artifact-type application/vnd.opentofu.modulepkg \
  out/module-package.zip:archive/zip

tree "$LAYOUT"
cat "$LAYOUT/index.json" | jq .
ls "$LAYOUT/blobs/sha256"
```

Copy layout → GHCR when ready:

```bash
oras cp --from-oci-layout "$LAYOUT:module-only" "ghcr.io/<owner>/infraweave-oci-spike:module-only"
```

---

## GHCR notes

| Topic | Guidance |
|-------|----------|
| Visibility | New packages are often **private**; grant read access or make the package public for `tofu init` from other machines |
| Image name | Must be lowercase: `ghcr.io/myorg/my-module` |
| Tags | Use distinct tags (`module-only`, `runnable`) on one repo, or separate repos — either works |
| Permissions | PAT needs `write:packages`; consumers need `read:packages` for private images |
| CI | `echo "${{ secrets.GITHUB_TOKEN }}" \| oras login ghcr.io -u ${{ github.actor }} --password-stdin` |

---

## Success criteria

- [ ] Image 1: manifest has `artifactType` `application/vnd.opentofu.modulepkg` and exactly one `archive/zip` layer
- [ ] Image 1: `tofu init` succeeds against `oci://ghcr.io/...?tag=module-only`
- [ ] Image 2: manifest has two layers (`archive/zip` + `application/vnd.infraweave.project.v1+zip`)
- [ ] Image 2: `tofu init` still succeeds when sourcing the same tag as a **module** (extra layer ignored)
- [ ] Both images visible in GitHub → Packages

---

## Follow-ups (out of spike scope)

- Add `application/vnd.infraweave.module.metadata.v1+json` and `application/vnd.infraweave.project.metadata.v1+json` layers ([layer stack](../oci-module/plan.md#layer-stack-runnable-module-image))
- Parity: compare `oras` manifest JSON with a future `oci-module` layout builder
- Runner spike: [`../oci-module-runner/plan.md`](../oci-module-runner/plan.md)
- Registry server integration: [`../oci-registry/plan.md`](../oci-registry/plan.md)

---

## References

- [OpenTofu — Module packages in OCI registries](https://opentofu.org/docs/cli/oci_registries/module-package/)
- [ORAS — `oras push`](https://oras.land/docs/commands/oras_push)
- [OCI image layout](https://github.com/opencontainers/image-spec/blob/main/image-layout.md) — [`docs_internal/specs/oci_image/image-layout.md`](../../../docs_internal/specs/oci_image/image-layout.md)
- Infraweave decisions: [`../oci-module/decisions.md`](../oci-module/decisions.md) (DEC-005, DEC-012, DEC-013)
