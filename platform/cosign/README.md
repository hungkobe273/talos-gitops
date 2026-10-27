# cosign public key

Jenkins (`jenkins-1`) signs every demo-app image digest that passed the scans, with the
key pair in `jenkins_home/.cosign/` (private key 600, never leaves the VM). No Rekor upload.

Check an image by hand:

    cosign verify --key platform/cosign/cosign.pub --insecure-ignore-tlog=true ghcr.io/hungkobe273/talos-demo-app@sha256:...

Not enforced in the cluster yet (next step: an admission policy that only admits images
signed with this key, e.g. Kyverno verifyImages or sigstore policy-controller).
