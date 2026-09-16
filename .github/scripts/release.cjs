const { readFile } = require('node:fs/promises');
const { join } = require('node:path');
const { createHash } = require('node:crypto');

const UPSTREAM = { owner: 'Aussiemon', repo: 'luajit-decompiler-v2' };
const UPSTREAM_URL = `https://github.com/${UPSTREAM.owner}/${UPSTREAM.repo}`;
const ARCHIVE = 'luajit-decompiler-v2-windows-x64.zip';
const CHECKSUMS = 'SHA256SUMS.txt';
const ASSETS = [ARCHIVE, CHECKSUMS];

function releaseTag(sha) {
  if (!/^[0-9a-f]{40}$/.test(sha)) throw new Error('Invalid upstream commit SHA');
  return `build-${sha}`;
}

async function findRelease(github, repository, tag) {
  // Listing releases also finds unpublished drafts left by interrupted uploads.
  for await (const page of github.paginate.iterator(github.rest.repos.listReleases, {
    ...repository,
    per_page: 100,
  })) {
    const release = page.data.find(item => item.tag_name === tag);
    if (release) return release;
  }
  return null;
}

function checkAssets(release) {
  for (const name of ASSETS) {
    const asset = release.assets.find(item => item.name === name);
    if (!asset || asset.state !== 'uploaded' || asset.size <= 0) {
      throw new Error(`Release ${release.tag_name} has no complete ${name}`);
    }
  }
}

async function check({ github, context, core }) {
  const { data: commit } = await github.rest.repos.getCommit({ ...UPSTREAM, ref: 'master' });
  const tag = releaseTag(commit.sha);
  const release = await findRelease(github, context.repo, tag);
  const published = release !== null && !release.draft;
  if (published) checkAssets(release);
  core.setOutput('sha', commit.sha);
  core.setOutput('needed', String(!published));
  core.info(published ? `${tag} is already published; no changes needed.` : `Build required for ${tag}.`);
}

async function readAssets(directory) {
  const archive = await readFile(join(directory, ARCHIVE));
  const checksums = await readFile(join(directory, CHECKSUMS));
  const hash = createHash('sha256').update(archive).digest('hex');
  if (archive.length === 0 || checksums.toString('utf8').trimEnd() !== `${hash}  ${ARCHIVE}`) {
    throw new Error('Release archive checksum mismatch');
  }
  return [
    { name: ARCHIVE, data: archive, type: 'application/zip' },
    { name: CHECKSUMS, data: checksums, type: 'text/plain' },
  ];
}

async function pushSourceTag(exec, sha, tag) {
  await exec.exec('git', ['fetch', '--no-tags', `${UPSTREAM_URL}.git`, sha]);
  const { stdout } = await exec.getExecOutput('git', ['rev-parse', 'FETCH_HEAD']);
  if (stdout.trim() !== sha) throw new Error('Fetched source does not match the requested commit');
  await exec.exec('git', ['tag', tag, sha]);
  // Never move an existing tag. A conflicting remote tag must fail visibly.
  await exec.exec('git', ['push', 'origin', `refs/tags/${tag}`]);
}

async function publish({ github, context, core, exec, sha, directory }) {
  const tag = releaseTag(sha);
  let release = await findRelease(github, context.repo, tag);
  if (release && !release.draft) {
    checkAssets(release);
    core.info(`${tag} is already published; leaving it unchanged.`);
    return;
  }

  const assets = await readAssets(directory);
  await pushSourceTag(exec, sha, tag);
  const name = `Build ${sha.slice(0, 12)} — Windows x64`;
  const body = [
    `Built from unmodified [upstream source](${UPSTREAM_URL}/commit/${sha}).`,
    '',
    'Windows x64, MSVC C++20, statically linked C++ runtime (/MT).',
    'The ZIP contains the executable, upstream license, and build metadata.',
    'SHA256SUMS.txt contains the archive checksum.',
    '',
    'Validation: compilation and CLI startup only; no game bytecode is included or tested in CI.',
    `Build workflow: https://github.com/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`,
  ].join('\n');

  if (!release) {
    ({ data: release } = await github.rest.repos.createRelease({
      ...context.repo,
      tag_name: tag,
      target_commitish: sha,
      name,
      body,
      draft: true,
      prerelease: false,
    }));
  }

  for (const asset of assets) {
    const previous = release.assets.find(item => item.name === asset.name);
    if (previous) {
      await github.rest.repos.deleteReleaseAsset({ ...context.repo, asset_id: previous.id });
    }
    await github.rest.repos.uploadReleaseAsset({
      ...context.repo,
      release_id: release.id,
      name: asset.name,
      data: asset.data,
      headers: { 'content-type': asset.type, 'content-length': asset.data.length },
    });
  }

  const { data: uploaded } = await github.rest.repos.getRelease({ ...context.repo, release_id: release.id });
  checkAssets(uploaded);
  const { data: published } = await github.rest.repos.updateRelease({
    ...context.repo,
    release_id: release.id,
    name,
    body,
    draft: false,
    prerelease: false,
    make_latest: 'true',
  });
  core.info(`Published ${published.html_url}`);
}

module.exports = { check, publish };
