from pathlib import Path


def test_ci_and_release_workflows_publish_expected_tags():
    ci = Path(".github/workflows/ci.yml").read_text(encoding="utf-8")
    release = Path(".github/workflows/release.yml").read_text(encoding="utf-8")

    assert "python -m invoke black-check" in ci
    assert "python -m invoke flake8-check" in ci
    assert "python -m invoke test-python" in ci
    assert "python -m invoke check-js" in ci
    assert "linux/amd64" in ci and "linux/arm64" in ci
    assert "sha-${{ github.sha }}" in ci
    assert "workflow_run:" in release
    assert '--tag "$IMAGE:$RELEASE_VERSION"' in release
    assert '--tag "$IMAGE:latest"' in release
    assert "WEBHOOKER_PRODUCTION_WAKE_URL" in release


def test_webhooker_bundle_matches_published_image_contract():
    production = Path("deploy/webhooker/config/tracy-production.yaml").read_text(encoding="utf-8")
    review = Path("deploy/webhooker/config/tracy-review.yaml").read_text(encoding="utf-8")
    production_compose = Path("deploy/webhooker/compose.production.yml").read_text(encoding="utf-8")
    review_workflow = Path(".github/workflows/pr-review.yml").read_text(encoding="utf-8")

    assert "repository: malaber/tracy" in production
    assert "production_tag_template: sha-{sha}" in production
    assert "tag_template: pr-{pr}-{sha7}" in review
    assert "image: ${APP_IMAGE}" in production_compose
    assert "WEBHOOKER_REVIEW_WAKE_URL" in review_workflow
    assert "pr-${{ github.event.pull_request.number }}.pr.tracy.malaber.de" in review_workflow
