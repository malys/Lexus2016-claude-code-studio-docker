# Release / dispatch notes

## Recommended CCS release hook

From the CCS repository's release workflow, dispatch this repository's workflow with:

```yaml
- name: Rebuild full Docker image
  env:
    FULL_IMAGE_REPO: malys/Lexus2016-claude-code-studio-docker
  run: |
    gh api repos/${FULL_IMAGE_REPO}/dispatches \
      --method POST \
      -f event_type=ccs-release \
      -f client_payload[ccs_ref]=${GITHUB_REF_NAME} \
      -f client_payload[version]=${GITHUB_REF_NAME#v}
```

Change `FULL_IMAGE_REPO` to the actual owner/repository once the new GitHub repository is finalized.

## GHCR package naming

The workflow publishes to the repository owner's GHCR namespace by default:

`ghcr.io/<repository-owner>/claude-code-studio`

This is important because the default `GITHUB_TOKEN` can publish the package for the repository owner. If the repository is moved to `Lexus2016`, the image becomes `ghcr.io/lexus2016/claude-code-studio` automatically.
