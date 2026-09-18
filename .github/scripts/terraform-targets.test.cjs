const test = require('node:test');
const assert = require('node:assert/strict');
const select = require('./terraform-targets.cjs');
const {targetsForFiles, hasCurrentApproval} = select;

const head = 'a'.repeat(40);
const merge = 'b'.repeat(40);
const pr = {
  number: 1, user: {id: 1}, base: {ref: 'main'},
  head: {sha: head, repo: {full_name: 'owner/repo'}},
  merged: true, merge_commit_sha: merge, changed_files: 1,
};
const approval = {
  user: {id: 2, type: 'User'}, state: 'APPROVED', commit_id: head,
  author_association: 'COLLABORATOR',
};
const root = (environment, cloud) => ({environment, cloud});
const files = (...paths) => paths.map(filename => ({filename}));

test('dev changes plan only dev for the matching cloud', () => {
  assert.deepEqual(targetsForFiles(files('terraform-multicloud-network/environments/dev/network/gcp/main.tf'), ['aws', 'gcp']), [root('dev', 'gcp')]);
});
test('prod changes plan only prod', () => {
  assert.deepEqual(targetsForFiles(files('terraform-multicloud-network/environments/prod/network/aws/terraform.tfvars'), ['aws', 'gcp']), [root('prod', 'aws')]);
});
test('UAT folder changes select an isolated UAT plan', () => {
  assert.deepEqual(targetsForFiles(files('terraform-multicloud-network/environments/uat/network/gcp/main.tf'), ['gcp']), [root('uat', 'gcp')]);
});
test('shared changes never select on-demand UAT', () => {
  for (const path of ['.github/workflows/uat.yml', 'terraform-multicloud-network/modules/network/gcp/main.tf']) {
    assert.equal(targetsForFiles(files(path), ['gcp']).some(target => target.environment === 'uat'), false);
  }
});
test('shared module changes select both environments without duplicates', () => {
  assert.deepEqual(targetsForFiles(files('terraform-multicloud-network/modules/network/gcp/main.tf', 'terraform-multicloud-network/environments/dev/network/gcp/main.tf'), ['gcp']), [root('dev', 'gcp'), root('prod', 'gcp')]);
});
test('platform module changes select the affected cloud', () => {
  assert.deepEqual(targetsForFiles(files('terraform-multicloud-network/modules/platform/aws/main.tf'), ['aws', 'gcp']), [root('dev', 'aws'), root('prod', 'aws')]);
});
test('VPN bootstrap changes select every persistent target', () => {
  assert.equal(targetsForFiles(files('terraform-multicloud-network/modules/platform/openvpn-bootstrap.sh.tftpl'), ['aws', 'gcp']).length, 4);
});
test('shared workflow changes select all enabled roots', () => {
  assert.equal(targetsForFiles(files('.github/workflows/terraform.yml'), ['aws', 'gcp']).length, 4);
});
test('documentation and disabled clouds do not deploy', () => {
  assert.deepEqual(targetsForFiles(files('.github/README.md', 'terraform-multicloud-network/environments/prod/network/azure/main.tf'), ['gcp']), []);
});
test('renames include old and new roots', () => {
  assert.deepEqual(targetsForFiles([{
    filename: 'terraform-multicloud-network/environments/prod/network/gcp/main.tf',
    previous_filename: 'terraform-multicloud-network/environments/dev/network/gcp/main.tf',
  }], ['gcp']), [root('dev', 'gcp'), root('prod', 'gcp')]);
});
test('only current independent collaborator approval permits apply', () => {
  assert.equal(hasCurrentApproval([approval], pr), true);
  for (const change of [
    {commit_id: merge}, {user: {id: 1, type: 'User'}}, {state: 'DISMISSED'},
    {author_association: 'NONE'}, {user: {id: 2, type: 'Bot'}},
  ]) assert.equal(hasCurrentApproval([{...approval, ...change}], pr), false);
  assert.equal(hasCurrentApproval([], pr), false);
});
test('dismissed approvals and outstanding changes block apply', () => {
  assert.equal(hasCurrentApproval([approval, {...approval, state: 'DISMISSED'}], pr), false);
  assert.equal(hasCurrentApproval([approval, {...approval, user: {id: 3}, state: 'CHANGES_REQUESTED'}], pr), false);
});
test('a comment does not revoke an approval', () => {
  assert.equal(hasCurrentApproval([approval, {...approval, state: 'COMMENTED'}], pr), true);
});

async function run({action = 'opened', pull = pr, changed = files('terraform-multicloud-network/environments/dev/network/gcp/main.tf'), reviews = [approval], env = {}, manual = false, ref = 'refs/heads/main'} = {}) {
  const outputs = {};
  const github = {
    rest: {pulls: {listFiles: 'files', listReviews: 'reviews'}},
    paginate: async endpoint => endpoint === 'files' ? changed : reviews,
  };
  await select({github,
    context: {payload: {action, pull_request: manual ? undefined : pull, repository: {full_name: 'owner/repo'}}, repo: {owner: 'owner', repo: 'repo'}, sha: head, ref},
    core: {setOutput: (key, value) => { outputs[key] = value; }, info() {}},
    env: {ENABLED_CLOUDS: '["gcp"]', ...env},
  });
  return outputs;
}
test('open PR plans the PR merge ref and never applies', async () => {
  const result = await run();
  assert.equal(result.apply, false);
  assert.equal(result.ref, head);
});
test('approved merge plans and applies the exact merged commit', async () => {
  const result = await run({action: 'closed'});
  assert.equal(result.apply, true);
  assert.equal(result.ref, merge);
});
test('an unapproved merge fails', async () => {
  await assert.rejects(run({action: 'closed', reviews: []}), /requires approval/);
});
test('fork PRs and incomplete file lists fail before cloud access', async () => {
  await assert.rejects(run({pull: {...pr, head: {...pr.head, repo: {full_name: 'fork/repo'}}}}), /fork PRs/);
  await assert.rejects(run({pull: {...pr, changed_files: 2}}), /Incomplete/);
});
test('documentation-only PR skips Terraform', async () => {
  const result = await run({changed: files('README.md')});
  assert.equal(result['has-targets'], false);
});
test('manual runs only plan a validated target from main or master', async () => {
  const env = {MANUAL_CLOUD: 'gcp', MANUAL_ENVIRONMENT: 'prod'};
  const result = await run({manual: true, env});
  assert.equal(result.apply, false);
  assert.deepEqual(result.matrix.include, [root('prod', 'gcp')]);
  await assert.rejects(run({manual: true, env, ref: 'refs/heads/feature'}), /main or master/);
  await assert.rejects(run({manual: true, env: {...env, MANUAL_ENVIRONMENT: '../dev'}}), /Invalid/);
});
test('invalid enabled cloud configuration fails', async () => {
  for (const ENABLED_CLOUDS of ['[]', '["other"]', '["gcp","gcp"]']) {
    await assert.rejects(run({env: {ENABLED_CLOUDS}}), /TF_ENABLED_CLOUDS/);
  }
});
test('manual UAT preview stays plan-only', async () => {
  const result = await run({manual: true, env: {MANUAL_CLOUD: 'gcp', MANUAL_ENVIRONMENT: 'uat'}});
  assert.equal(result.apply, false);
  assert.deepEqual(result.matrix.include, [root('uat', 'gcp')]);
});
