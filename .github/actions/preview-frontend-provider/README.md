<br>

## About

vercel 과 같은 frontend 의 preview URL 을 제공합니다.<br>
preview URL 은 사내 VPN 에서만 접근 가능합니다.<br>
<br>
[관련 문서](https://lunit.atlassian.net/wiki/spaces/CPSI/pages/2861433101/Preview+Frontend+Provider)

<div align="center">
<img width="500" alt="스크린샷 2023-02-10 오후 5 25 45" src="https://user-images.githubusercontent.com/63000843/218041095-d72d92b7-e31e-443e-ac23-d0958ec4f0e5.png">
</div>

<br>

## Usage

```yml
name: Preview Frontend Provider
run-name: Preview Action

on:
  pull_request:
    branches: [ feature ]
    types: [ synchronize, opened, closed ]

jobs:
  preview:
    # Important
    # If private repo, use [ csg-sd-runner, al2_x86_64 ]
    runs-on: [ csg-sd-runner, al2_x86_64 ]
    
    # If public repo, use ubuntu-latest
    runs-on: ubuntu-latest
    
    steps:
      # Required
      - uses: actions/checkout@v3

      # 아래 빌드 과정은 각자 커스텀 !!
      - uses: actions/setup-node@v3
        if: github.event.pull_request.merged == false && !contains(github.event.action, 'closed')
        with:
          node-version: 18

      - name: build
        if: github.event.pull_request.merged == false && !contains(github.event.action, 'closed')
        env:
          CI: false
        run: |
          npm ci
          npm run build

      # Required
      - name: preview-frontend-provider
        id: preview-frontend-provider
        uses: lunit-io/csg-sd-gitops/git-actions/preview-frontend-provider@v1.3.0 # Latest Version
        with:
          pfp-access-key: ${{ secrets.PFP_ACCESS_KEY }}
          pfp-secret-key: ${{ secrets.PFP_SECRET_KEY }}

          # Optional
          build-path: /build # default build
          use-public-runner: true # default false

      # Required
      - uses: NejcZdovc/comment-pr@v2
        with:
          message: |
            ✅ Preview 
            ${{ steps.preview-frontend-provider.outputs.random-url }}
        env:
          GITHUB_TOKEN: ${{secrets.GITHUB_TOKEN}}
```

- git-token 은 PR 에 review 달때 사용됨
- 해당 액션은 event 가 `pull-request` 일때만 동작함
- 캐싱을 사용한다면, 캐싱 경로는 `/build-cache/<npm cache path>`
- PR 이 merge 가 된다면 해당 PR 에서 생성된 모든 미리보기 URL 은 제거됨 <br>아래 코드와 같은 조건을 만족하는 액션을 발생시킬 경우 발동 (필수는 아니나 권장됨)

```shell
if [ "${GIT_EVENT_NAME}" == "pull_request" ] && [ "${GIT_EVENT_PR_MERGED}" == "true" ];then
  delete_from_s3
  delete_url_info_from_csv
fi
```

<br>

## Inputs

아래 inputs 은 `step.with` keys 로 사용합니다.

> `Optional` is able to be ignored

| Name                | Type   | Description                                       |
|---------------------|--------|---------------------------------------------------|
| `pfp-access-key`    | String | AWS_ACCESS_KEY_ID 를 secrets 로 받음                  |
| `pfp-secret-key`    | String | AWS_ACCESS_SECRET_KEY 를 secrets 로 받음              |
| `use-public-runner` | String | public runner 를 사용할 경우 `true` (default false)     |
| `build-path`        | String | `npm build` 할 경우 생성되는 build 폴더 경로 (default build) |
