const clouds = ['aws', 'gcp', 'azure'];
const environments = ['dev', 'prod'];
const manualEnvironments = [...environments, 'uat'];

function targetsForFiles(files, enabledClouds) {
  const selected = new Map();
  const add = (environment, cloud) => {
    if (enabledClouds.includes(cloud)) {
      selected.set(`${environment}/${cloud}`, {environment, cloud});
    }
  };
  for (const file of files) {
    // Include both sides of renames so moving a root cannot hide its old target.
    for (const path of [file.filename, file.previous_filename].filter(Boolean)) {
      const root = path.match(/^terraform-multicloud-network\/environments\/(dev|uat|prod)\/network\/(aws|gcp|azure)\//);
      const module = path.match(/^terraform-multicloud-network\/modules\/(network|platform)\/(aws|gcp|azure)\//);
      if (root) add(root[1], root[2]);
      else if (module) environments.forEach(environment => add(environment, module[2]));
      else if (/^\.github\/(workflows|actions|scripts)\//.test(path) ||
               path === 'terraform-multicloud-network/deploy.sh' ||
               path === 'terraform-multicloud-network/modules/platform/openvpn-bootstrap.sh.tftpl' ||
               path.startsWith('terraform-multicloud-network/environments/network/')) {
        // Shared automation and migration from the old layout affect every root.
        environments.forEach(environment => enabledClouds.forEach(cloud => add(environment, cloud)));
      }
    }
  }
  return [...selected.values()].sort((a, b) =>
    `${a.environment}/${a.cloud}`.localeCompare(`${b.environment}/${b.cloud}`));
}

function hasCurrentApproval(reviews, pr) {
  const latest = new Map();
  for (const review of reviews) {
    if (['APPROVED', 'CHANGES_REQUESTED', 'DISMISSED'].includes(review.state)) {
      latest.set(review.user.id, review);
    }
  }
  const decisions = [...latest.values()];
  return !decisions.some(review => review.state === 'CHANGES_REQUESTED') &&
    decisions.some(review => review.state === 'APPROVED' && review.commit_id === pr.head.sha &&
      review.user.id !== pr.user.id && review.user.type === 'User' &&
      ['OWNER', 'MEMBER', 'COLLABORATOR'].includes(review.author_association));
}

module.exports = async function select({github, context, core, env = process.env}) {
  const enabled = JSON.parse(env.ENABLED_CLOUDS || '["aws","gcp"]');
  if (!Array.isArray(enabled) || !enabled.length || enabled.some(cloud => !clouds.includes(cloud)) ||
      new Set(enabled).size !== enabled.length) {
    throw new Error('TF_ENABLED_CLOUDS must be a nonempty JSON array of unique cloud names.');
  }
  const pr = context.payload.pull_request;
  const apply = context.payload.action === 'closed' && pr?.merged === true;
  let targets;
  if (pr) {
    if (!['main', 'master'].includes(pr.base.ref)) throw new Error('Unsupported PR base branch.');
    if (pr.head.repo?.full_name !== context.payload.repository.full_name) {
      throw new Error('Cloud plans for fork PRs are disabled. A maintainer must review and reproduce the change on a trusted branch.');
    }
    const files = await github.paginate(github.rest.pulls.listFiles, {
      ...context.repo, pull_number: pr.number, per_page: 100,
    });
    // GitHub caps this endpoint at 3,000 files; never silently miss a target.
    if (pr.changed_files > files.length || files.length >= 3000) {
      throw new Error('Incomplete PR file list. Split this PR before running Terraform.');
    }
    targets = targetsForFiles(files, enabled);
    if (apply && targets.some(target => target.environment !== 'uat')) {
      const reviews = await github.paginate(github.rest.pulls.listReviews, {
        ...context.repo, pull_number: pr.number, per_page: 100,
      });
      if (!hasCurrentApproval(reviews, pr)) {
        throw new Error('Apply requires approval of the latest PR commit by another collaborator, with no outstanding change requests.');
      }
    }
  } else {
    if (!['refs/heads/main', 'refs/heads/master'].includes(context.ref)) {
      throw new Error('Manual plans must run from main or master.');
    }
    if (!clouds.includes(env.MANUAL_CLOUD) || !manualEnvironments.includes(env.MANUAL_ENVIRONMENT)) {
      throw new Error('Invalid manual target.');
    }
    targets = [{cloud: env.MANUAL_CLOUD, environment: env.MANUAL_ENVIRONMENT}];
  }
  const ref = apply ? pr.merge_commit_sha : context.sha;
  if (!/^[a-f0-9]{40}$/.test(ref || '')) throw new Error('Expected an exact commit SHA.');
  core.setOutput('matrix', {include: targets});
  core.setOutput('has-targets', targets.length > 0);
  core.setOutput('apply', apply);
  core.setOutput('ref', ref);
  core.info(`Selected: ${targets.map(target => `${target.environment}/${target.cloud}`).join(', ') || 'no infrastructure changes'}`);
};

module.exports.targetsForFiles = targetsForFiles;
module.exports.hasCurrentApproval = hasCurrentApproval;
