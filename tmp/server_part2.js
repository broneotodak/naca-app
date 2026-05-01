
// ════════════════════════════════════════════════════════════════════
// GITHUB WEBHOOK RELAY (Phase 2 C)
//
// GitHub POSTs events here → we verify HMAC, classify by event type,
// and route to agent_commands (direct, known-handler) or agent_intents
// (planner decomposes into specific commands). This avoids the silent
// stall where events were queued as commands no agent accepts.
//
// Setup on each repo (one-time, via gh CLI or GitHub UI):
//   gh api -X POST /repos/{owner}/{repo}/hooks \
//     -f name=web -F active=true -f events[]=push -f events[]=pull_request \
//     -f events[]=check_suite -f events[]=issue_comment \
//     -f config[url]=https://naca.neotodak.com/api/webhooks/github \
//     -f config[content_type]=json -f config[secret]=$GITHUB_WEBHOOK_SECRET
// ════════════════════════════════════════════════════════════════════
function handleGithubWebhook(req, res) {
  const secret = process.env.GITHUB_WEBHOOK_SECRET;
  if (!secret) { res.writeHead(503, { 'Content-Type': 'application/json' }); res.end('{"error":"webhook secret not configured"}'); return; }

  const sig = req.headers['x-hub-signature-256'];
  const event = req.headers['x-github-event'];
  const deliveryId = req.headers['x-github-delivery'];
  if (!sig || !event) { res.writeHead(400, { 'Content-Type': 'application/json' }); res.end('{"error":"missing GitHub headers"}'); return; }

  // Read raw body for signature verification (must be exact bytes GitHub signed)
  let raw = '';
  req.on('data', c => raw += c);
  req.on('end', async () => {
    try {
      const expected = 'sha256=' + crypto.createHmac('sha256', secret).update(raw).digest('hex');
      const valid = sig.length === expected.length && crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected));
      if (!valid) { res.writeHead(401, { 'Content-Type': 'application/json' }); res.end('{"error":"signature mismatch"}'); return; }

      let payload;
      try { payload = JSON.parse(raw); } catch { res.writeHead(400, { 'Content-Type': 'application/json' }); res.end('{"error":"bad json"}'); return; }

      const repo = payload.repository?.full_name || 'unknown';
      const commands = []; // routes to agent_commands (only for direct, known-command targets)
      const intents  = []; // routes to agent_intents (planner decomposes into known commands)

      // ── event mappings ─────────────────────────────────────────────────
      // Routing rule:
      //   Direct → commands: only when we KNOW the receiving agent + command
      //     (currently just reviewer/review_pr for opened PRs).
      //   Indirect → intents: anything where the right agent + sub-command
      //     should be decided by the planner. This avoids the "stuck command"
      //     class of bug where webhooks queued commands no agent accepts.
      //
      switch (event) {
        case 'push': {
          // Push to main = "something landed on main, decide if any follow-up needed"
          const branch = (payload.ref || '').replace('refs/heads/', '');
          if (branch === 'main' || branch === 'master') {
            const head = payload.head_commit;
            intents.push({
              source: 'github_webhook',
              reporter: head?.author?.username || head?.author?.name || 'github-actions',
              raw_text: `[github] push to ${repo}@${branch} — ${payload.commits?.length || 0} commit(s). HEAD: "${(head?.message || '').slice(0, 200)}". Decide whether any follow-up agent action is needed (likely no-op for routine merges; investigate if commit indicates a fix that needs verification).`,
              source_ref: JSON.stringify({ event: 'push', repo, branch, head_sha: head?.id, commits_count: payload.commits?.length || 0 }),
              status: 'pending',
            });
          }
          break;
        }
        case 'pull_request': {
          // Opened / synchronized → reviewer (DIRECT — known agent + command).
          // Contract: to_agent='reviewer', command='review_pr', payload needs { project, repo, branch }.
          if (['opened', 'synchronize', 'reopened', 'ready_for_review'].includes(payload.action)) {
            const project = repo.split('/').pop() || repo;
            const branch = payload.pull_request?.head?.ref;
            commands.push({
              from_agent: 'github-actions',
              to_agent: 'reviewer',
              command: 'review_pr',
              payload: {
                project,
                repo,
                branch,
                pr_number: payload.pull_request?.number,
                pr_title: payload.pull_request?.title,
                pr_url: payload.pull_request?.html_url,
                head_sha: payload.pull_request?.head?.sha,
                base: payload.pull_request?.base?.ref,
                action: payload.action,
                reporter: payload.pull_request?.user?.login,
              },
              priority: 3,
            });
          }
          // Closed/merged → INTENT (planner decides: deploy notify? cleanup? no-op?).
          if (payload.action === 'closed' && payload.pull_request?.merged) {
            const pr = payload.pull_request;
            intents.push({
              source: 'github_webhook',
              reporter: pr.merged_by?.login || 'github-actions',
              raw_text: `[github] PR merged on ${repo}: #${pr.number} "${pr.title}" by @${pr.merged_by?.login || 'unknown'}. Decide if any post-merge action is needed.`,
              source_ref: JSON.stringify({ event: 'pull_request', action: 'merged', repo, pr_number: pr.number, pr_url: pr.html_url, merged_by: pr.merged_by?.login }),
              status: 'pending',
            });
          }
          break;
        }
        case 'check_suite': {
          // CI check_suite failure → INTENT (planner decomposes into investigate_bug or no-op).
          if (payload.action === 'completed' && payload.check_suite?.conclusion === 'failure') {
            const cs = payload.check_suite;
            intents.push({
              source: 'github_webhook',
              reporter: 'github-actions',
              raw_text: `[github] CI check_suite failed on ${repo}@${cs.head_branch} (${(cs.head_sha || '').slice(0, 8)}). Failing app: ${cs.app?.slug || 'unknown'}. Investigate which check failed (likely build, lint, or test) and propose a fix if it's a real regression. Skip if the failing workflow is known-flaky or unsupported (e.g. Build Windows on a non-Windows project).`,
              source_ref: JSON.stringify({ event: 'check_suite', repo, head_sha: cs.head_sha, branch: cs.head_branch, app: cs.app?.slug, conclusion: cs.conclusion }),
              status: 'pending',
            });
          }
          break;
        }
        case 'issue_comment': {
          // Comments mentioning an agent → INTENT (planner reads the body and decides what to do).
          const body = payload.comment?.body || '';
          const mentioned = ['dev-agent', 'planner-agent', 'reviewer-agent', 'siti'].filter(t => body.includes('@' + t));
          if (mentioned.length) {
            intents.push({
              source: 'github_webhook',
              reporter: payload.comment?.user?.login || 'github-actions',
              raw_text: `[github] mention on ${repo} issue/PR #${payload.issue?.number}: "${body.slice(0, 400)}". Mentioned: ${mentioned.join(', ')}. Decide which agent should respond and how.`,
              source_ref: JSON.stringify({ event: 'issue_comment', repo, issue_number: payload.issue?.number, comment_url: payload.comment?.html_url, mentioned, author: payload.comment?.user?.login }),
              status: 'pending',
            });
          }
          break;
        }
        case 'ping': {
          // GitHub's setup ping — just acknowledge.
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: true, event: 'ping', delivery: deliveryId }));
          return;
        }
        default: {
          // Unhandled event — accept but record nothing
          console.log(`[github-webhook] unhandled event '${event}' from ${repo} (delivery ${deliveryId})`);
        }
      }

      // Guard: if neo-brain is not connected, we can't persist anything.
      // Fail loudly so the caller (GitHub) retries later.
      if ((commands.length || intents.length) && !supabase) {
        console.error(`[github-webhook] ${event} from ${repo} produced ${commands.length} cmd(s) + ${intents.length} intent(s) but supabase not configured — events dropped`);
        res.writeHead(503, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'neo-brain not configured, events not persisted' }));
        return;
      }

      // Insert queued commands + intents in two shots via Supabase REST.
      // Commands route to known-handler agents (reviewer for review_pr).
      // Intents route to planner for decomposition (everything else from webhooks).
      let insertedCommands = 0;
      let insertedIntents  = 0;
      let intentError = null;
      if (commands.length && supabase) {
        const { data, error } = await supabase.from('agent_commands').insert(commands).select('id');
        if (error) {
          console.error('[github-webhook] commands insert failed:', error.message);
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: error.message }));
          return;
        }
        insertedCommands = data?.length || 0;
      }
      if (intents.length && supabase) {
        const { data, error } = await supabase.from('agent_intents').insert(intents).select('id');
        if (error) {
          console.error('[github-webhook] intents insert failed:', error.message);
          intentError = error.message;
        } else {
          insertedIntents = data?.length || 0;
        }
      }

      console.log(`[github-webhook] ${event}/${payload.action || '-'} from ${repo} → ${insertedCommands} command(s), ${insertedIntents} intent(s)${intentError ? ' (intent error: ' + intentError + ')' : ''}`);
      const statusCode = intentError && !insertedCommands ? 500 : 200;
      res.writeHead(statusCode, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: !intentError, event, action: payload.action || null, repo, commands: insertedCommands, intents: insertedIntents, intent_error: intentError || undefined, delivery: deliveryId }));
    } catch (e) {
      console.error('[github-webhook] error:', e.message);
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: e.message }));
    }
  });
}

