build:
    zig build

test:
    zig build test
    bats test/

release:
    #!/usr/bin/env sh
    export GITHUB_TOKEN=$(gh auth token)
    goreleaser release --clean

clean:
    rm -rf zig-out/ .zig-cache/ dist/ dist-prebuilt/
