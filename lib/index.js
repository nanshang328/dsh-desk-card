/**
 * dsh-desk-card · 宿主半侧 / host half
 *
 * 右下角原生卡片：审批 / 提问 / 完成 / 报错。卡片是自绘 WPF 窗口（不依赖系统通知
 * 服务），全屏游戏或勿扰模式下自动跳过；审批卡片上可直接「确认允许」，或点卡片把
 * DSH 窗口拉到前台，把决定权交回界面。
 *
 * Native bottom-right cards for approvals / questions / turn completion / errors.
 * Self-drawn WPF window (no dependency on the system notification service); skipped
 * while a fullscreen app or Do-Not-Disturb is active. The approval card can be
 * accepted directly, or clicked to bring the DSH window to the front.
 *
 * 本插件不读任何外部配置文件：所有参数来自 bundle patch 里这一行的 config。
 * 日志 / log: %TEMP%\dsh-desk-card.log
 *
 * @module dsh-desk-card
 */

import { spawn } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const name = 'dsh-desk-card';

const HERE = dirname(fileURLToPath(import.meta.url));
const CARD_SCRIPT = join(HERE, '..', 'scripts', 'card.ps1');
const LOG = join(tmpdir(), 'dsh-desk-card.log');

function dbg(message) {
  try {
    appendFileSync(LOG, `${new Date().toISOString()} ${message}\n`, 'utf8');
  } catch {
    /* 日志写不进去不影响功能 */
  }
}

const openCards = new Set();

function closeCard(child, tag) {
  if (child === undefined || child === null) return;
  try {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill();
      dbg(`closeCard[${tag}]: killed pid=${child.pid}`);
    }
  } catch (error) {
    dbg(`closeCard[${tag}] failed: ${error?.message ?? error}`);
  }
}

function closeAllCards() {
  for (const child of [...openCards]) closeCard(child, 'dispose');
  openCards.clear();
}

/**
 * 弹一张卡片；绝不 detached（Windows 下 detached 会让 PowerShell 静默退出）。
 *
 * `timeoutSeconds` 是这张卡片自己的自动关闭秒数：0 = 一直留着等用户处理。
 * 省略时回落到 settings.timeoutSeconds。规则：**要用户点确定的卡片（审批 / 提问）
 * 一律 0**，只有纯提示性质的卡片（完成）才传正数，免得看完之前就消失。
 */
function showCard(settings, payload, tag, timeoutSeconds) {
  try {
    const timeout = Number.isFinite(timeoutSeconds) ? timeoutSeconds : (settings.timeoutSeconds ?? 0);
    const encoded = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64');
    const child = spawn(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', CARD_SCRIPT,
        '-Payload', encoded,
        '-TimeoutSeconds', String(timeout),
        '-Scale', String(settings.scale ?? 1.2),
        '-SkipWhenFullscreen', settings.skipWhenFullscreen === false ? 'false' : 'true',
        '-HostPid', String(process.pid),
        '-DebugLog', LOG,
      ],
      { stdio: 'ignore', windowsHide: true },
    );
    openCards.add(child);
    child.on('error', (error) => dbg(`showCard[${tag}]: spawn error ${error?.message ?? error}`));
    child.on('exit', (code) => {
      openCards.delete(child);
      dbg(`showCard[${tag}]: exit ${code}`);
    });
    child.unref();
    return child;
  } catch (error) {
    dbg(`showCard[${tag}] threw: ${error?.stack ?? error}`);
    return undefined;
  }
}

// ---------------------------------------------------------------- 文案 / strings

const TOOL_LABELS = {
  zh: {
    pwsh: 'PowerShell 命令',
    bash: 'Shell 命令',
    read: '读取文件',
    read_image: '查看图片',
    write: '写入文件',
    edit: '修改文件',
    glob: '查找文件',
    grep: '搜索文件内容',
    web_search: '联网搜索',
    web_fetch: '抓取网页',
    present: '交付文件',
    subagent: '委派子代理',
    subagent_fork: '委派子代理',
    workflow: '运行工作流',
    skill: '加载技能',
    todo_write: '更新任务清单',
    ask_user_question: '向你提问',
    create_goal: '创建目标',
    update_goal: '更新目标',
    get_goal: '查看目标',
    jobs: '后台任务',
  },
  en: {
    pwsh: 'PowerShell command',
    bash: 'shell command',
    read: 'file read',
    read_image: 'image read',
    write: 'file write',
    edit: 'file edit',
    glob: 'file search',
    grep: 'content search',
    web_search: 'web search',
    web_fetch: 'page fetch',
    present: 'file delivery',
    subagent: 'subagent',
    subagent_fork: 'subagent',
    workflow: 'workflow run',
    skill: 'skill load',
    todo_write: 'todo update',
    ask_user_question: 'question to you',
    create_goal: 'goal create',
    update_goal: 'goal update',
    get_goal: 'goal read',
    jobs: 'background jobs',
  },
};

const STRINGS = {
  zh: {
    approvalBadge: 'DSH 请求申请',
    questionBadge: 'DSH 等待回答',
    approvalHead: (label) => `关于「${label}」的请求申请`,
    questionHead: '关于「回答提问」的请求申请',
    errorBadge: 'DSH 任务出错',
    errorHead: (title) => (title ? `任务「${title}」出错` : '任务出错'),
    doneBadge: 'DSH 任务完成',
    doneHead: (title) => (title ? `任务「${title}」已完成` : '任务已完成'),
    unknownAction: '未知操作',
    browserAction: '浏览器操作',
    task: '任务',
    reason: '理由',
    question: '问题',
    error: '错误',
    turn: (turn, step) => (Number.isFinite(step) ? `第 ${turn} 轮第 ${step} 步` : `第 ${turn} 轮`),
    approvalHint: '点卡片查看详情，或直接确认放行',
    approvalFooter: '点卡片看详情（并打开 DSH）· 点「确认允许」直接放行',
    answerHint: '点卡片打开 DSH 界面回答',
    viewFooter: '点卡片打开 DSH 查看详情',
    allow: '确认允许',
    gotIt: '知道了',
    ack: '知晓',
    content: '大致内容',
    elapsed: '耗费时间',
    remaining: '剩余任务',
    remainingValue: (pending, doing, done) =>
      `${pending + doing} 项未完成（进行中 ${doing} / 待办 ${pending} / 已完成 ${done}）`,
    remainingNone: '—',
    tokensLine: (turn, session) => `消耗 token：${turn}（本会话累计 ${session}）`,
    seconds: (n) => `${n} 秒`,
    minutes: (m, s) => `${m} 分 ${s} 秒`,
    hours: (h, m) => `${h} 小时 ${m} 分`,
  },
  en: {
    approvalBadge: 'DSH approval request',
    questionBadge: 'DSH needs an answer',
    approvalHead: (label) => `Approval request: ${label}`,
    questionHead: 'DSH needs your answer',
    errorBadge: 'DSH task error',
    errorHead: (title) => (title ? `Task "${title}" failed` : 'Task failed'),
    doneBadge: 'DSH task finished',
    doneHead: (title) => (title ? `Task "${title}" finished` : 'Task finished'),
    unknownAction: 'unknown action',
    browserAction: 'browser action',
    task: 'Task',
    reason: 'Reason',
    question: 'Question',
    error: 'Error',
    turn: (turn, step) => (Number.isFinite(step) ? `turn ${turn}, step ${step}` : `turn ${turn}`),
    approvalHint: 'Click the card for details, or allow it right here',
    approvalFooter: 'Click the card for details (opens DSH) · "Allow" approves immediately',
    answerHint: 'Click the card to open DSH and answer',
    viewFooter: 'Click the card to open DSH for details',
    allow: 'Allow',
    gotIt: 'Got it',
    ack: 'OK',
    content: 'Summary',
    elapsed: 'Elapsed',
    remaining: 'Remaining',
    remainingValue: (pending, doing, done) =>
      `${pending + doing} open (${doing} running / ${pending} pending / ${done} done)`,
    remainingNone: '—',
    tokensLine: (turn, session) => `Tokens: ${turn} (session total ${session})`,
    seconds: (n) => `${n}s`,
    minutes: (m, s) => `${m}m ${s}s`,
    hours: (h, m) => `${h}h ${m}m`,
  },
};

function pickLanguage(configured) {
  if (configured === 'zh' || configured === 'en') return configured;
  try {
    const locale = String(Intl.DateTimeFormat().resolvedOptions().locale ?? '').toLowerCase();
    return locale.startsWith('zh') ? 'zh' : 'en';
  } catch {
    return 'en';
  }
}

function toolLabel(lang, toolName) {
  const table = TOOL_LABELS[lang] ?? TOOL_LABELS.en;
  const text = typeof toolName === 'string' && toolName.length > 0 ? toolName : (STRINGS[lang].unknownAction);
  if (Object.prototype.hasOwnProperty.call(table, text)) return table[text];
  if (text.startsWith('browser_')) return STRINGS[lang].browserAction;
  return text;
}

function clip(text, max) {
  const value = String(text ?? '').replace(/\s+/gu, ' ').trim();
  return value.length > max ? `${value.slice(0, max)}…` : value;
}

// ---------------------------------------------------------------- 会话摘要 / session facts

function eventsOf(agent) {
  try {
    return agent?.session?.snapshotEvents?.() ?? [];
  } catch {
    return [];
  }
}

function taskTitleOf(agent) {
  const events = eventsOf(agent);
  for (let i = events.length - 1; i >= 0; i -= 1) {
    const event = events[i];
    if (event?.type !== 'session/title') continue;
    const title = String(event.data?.title ?? '').trim();
    return title.length > 0 ? title.slice(0, 40) : '';
  }
  return '';
}

function lastUserText(agent) {
  const events = eventsOf(agent);
  for (let i = events.length - 1; i >= 0; i -= 1) {
    const event = events[i];
    if (event?.type !== 'user/message') continue;
    const data = event.data;
    let text = '';
    if (typeof data === 'string') text = data;
    else if (typeof data?.text === 'string') text = data.text;
    else if (typeof data?.content === 'string') text = data.content;
    else if (Array.isArray(data?.content)) {
      text = data.content.map((block) => (typeof block === 'string' ? block : (block?.text ?? ''))).join(' ');
    }
    const clipped = clip(text, 120);
    if (clipped.length > 0) return clipped;
  }
  return '';
}

function todoSummary(agent) {
  const events = eventsOf(agent);
  for (let i = events.length - 1; i >= 0; i -= 1) {
    const event = events[i];
    if (event?.type !== 'todo/write') continue;
    const todos = Array.isArray(event.data?.todos) ? event.data.todos : [];
    return {
      pending: todos.filter((todo) => todo?.status === 'pending').length,
      doing: todos.filter((todo) => todo?.status === 'in_progress').length,
      done: todos.filter((todo) => todo?.status === 'completed').length,
    };
  }
  return undefined;
}

const num = (value) => (Number.isFinite(Number(value)) ? Number(value) : 0);

function sessionTokens(agent) {
  const total = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0, total: 0 };
  for (const event of eventsOf(agent)) {
    let usage;
    if (event?.type === 'assistant/chunk' && event.data?.chunk?.type === 'usage') usage = event.data.chunk.usage;
    else if (event?.type === 'assistant/message' && event.data?.usage) usage = event.data.usage;
    if (usage === undefined) continue;
    total.input += num(usage.inputTokens);
    total.output += num(usage.outputTokens);
    total.cacheRead += num(usage.cacheReadTokens);
    total.cacheWrite += num(usage.cacheWriteTokens);
    total.reasoning += num(usage.reasoningTokens);
  }
  total.total = total.input + total.output + total.cacheRead + total.cacheWrite + total.reasoning;
  return total;
}

function lastTurnWasUnclean(agent) {
  const events = eventsOf(agent);
  for (let i = events.length - 1; i >= 0; i -= 1) {
    const event = events[i];
    if (event?.type !== 'turn/end') continue;
    return /error|aborted|interrupted|blocked/i.test(JSON.stringify(event.data?.reason ?? ''));
  }
  return false;
}

function formatTokens(value) {
  return Math.round(num(value)).toLocaleString('en-US');
}

function formatDuration(lang, ms) {
  const seconds = Math.max(0, Math.round(num(ms) / 1000));
  if (seconds < 60) return STRINGS[lang].seconds(seconds);
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return STRINGS[lang].minutes(minutes, seconds % 60);
  return STRINGS[lang].hours(Math.floor(minutes / 60), minutes % 60);
}

// ---------------------------------------------------------------- 插件 / plugin

export function apply(root, config) {
  const patch = config ?? {};
  const settings = () => ({
    // 审批 / 提问卡片：0 = 一直存在，不自动消失（要等用户点确定）。
    timeoutSeconds: Number.isFinite(patch.timeoutSeconds) ? patch.timeoutSeconds : 0,
    // 完成提示卡片：只是告知，默认 5 秒后自动关闭；设 0 可让它也一直留着。
    doneTimeoutSeconds:
      Number.isFinite(patch.doneTimeoutSeconds) && patch.doneTimeoutSeconds >= 0 ? patch.doneTimeoutSeconds : 5,
    scale: Number.isFinite(patch.scale) && patch.scale > 0 ? patch.scale : 1.2,
    skipWhenFullscreen: patch.skipWhenFullscreen !== false,
    notifyQuestions: patch.notifyQuestions !== false,
    notifyErrors: patch.notifyErrors !== false,
    notifyDone: patch.notifyDone !== false,
    language: pickLanguage(patch.language),
    hostProcess:
      typeof patch.hostProcess === 'string' && patch.hostProcess.length > 0 ? patch.hostProcess : 'DeepSeek Harness',
  });

  dbg(`apply() started config=${JSON.stringify(patch)}`);

  const options = { global: true, prepend: true };

  // ① 审批：本插件当 answerer。「确认允许」→ allowed-once；点卡片 → 打开 DSH 并把
  //    决定权交回去；卡片被跳过 / 失败 / 请求取消 → 交回下游或返回 cancelled。
  try {
    root.on(
      'approval/request',
      (request, next) => {
        const active = settings();
        const s = STRINGS[active.language];
        const taskTitle = taskTitleOf(request?.agent);
        const label = toolLabel(active.language, request?.toolName);
        const lines = [];
        if (taskTitle) lines.push(`${s.task}：${taskTitle}`);
        const reason = clip(request?.reason, 220);
        if (reason) lines.push(`${s.reason}：${reason}`);
        lines.push(s.approvalHint);
        const child = showCard(
          active,
          {
            badge: s.approvalBadge,
            head: s.approvalHead(label),
            body: lines.join('\n'),
            footer: s.approvalFooter,
            okLabel: s.allow,
            okCode: 10,
            hostProcess: active.hostProcess,
          },
          'approval',
        );

        return new Promise((resolve) => {
          let settled = false;
          const finish = (outcome) => {
            if (settled) return;
            settled = true;
            dbg(`approval resolved: ${outcome}`);
            resolve(outcome);
          };
          const delegate = (why) => {
            dbg(`approval delegated (${why})`);
            Promise.resolve()
              .then(() => next())
              .then(
                (outcome) => {
                  closeCard(child, 'approval');
                  finish(typeof outcome === 'string' ? outcome : 'unavailable');
                },
                (error) => {
                  closeCard(child, 'approval');
                  dbg(`downstream failed: ${error?.message ?? error}`);
                  finish('unavailable');
                },
              );
          };

          if (child === undefined) {
            delegate('no card');
            return;
          }
          try {
            request?.signal?.addEventListener?.('abort', () => {
              closeCard(child, 'approval');
              finish('cancelled');
            });
          } catch {
            /* 没有 signal 也能继续 */
          }
          child.on('exit', (code) => {
            if (settled) return;
            if (code === 10) {
              finish('allowed-once');
              return;
            }
            if (code === 12) {
              delegate('user asked for details');
              return;
            }
            delegate(`card exit ${code}`);
          });
        });
      },
      options,
    );
    dbg('listener: approval/request');
  } catch (error) {
    dbg(`approval listener failed: ${error?.stack ?? error}`);
  }

  // ② 提问：只提醒，链路立刻交回 DSH 界面收答案。
  try {
    root.on(
      'user-questions/request',
      (request, next) => {
        const active = settings();
        if (active.notifyQuestions) {
          const s = STRINGS[active.language];
          const taskTitle = taskTitleOf(request?.agent);
          const first = Array.isArray(request?.questions) ? request.questions[0] : undefined;
          const lines = [];
          if (taskTitle) lines.push(`${s.task}：${taskTitle}`);
          const question = clip(first?.question, 200);
          if (question) lines.push(`${s.question}：${question}`);
          lines.push(s.answerHint);
          const child = showCard(
            active,
            {
              badge: s.questionBadge,
              head: s.questionHead,
              body: lines.join('\n'),
              footer: s.answerHint,
              okLabel: s.gotIt,
              okCode: 10,
              hostProcess: active.hostProcess,
            },
            'question',
          );
          const outcome = next();
          Promise.resolve(outcome).then(
            () => closeCard(child, 'question'),
            () => closeCard(child, 'question'),
          );
          return outcome;
        }
        return next();
      },
      options,
    );
    dbg('listener: user-questions/request');
  } catch (error) {
    dbg(`question listener failed: ${error?.stack ?? error}`);
  }

  // ③ 报错卡片
  try {
    root.on(
      'agent/error',
      (payload) => {
        const active = settings();
        if (!active.notifyErrors) return;
        const s = STRINGS[active.language];
        const taskTitle = taskTitleOf(payload?.agent);
        const failure = payload?.error;
        const message = clip(failure instanceof Error ? failure.message : String(failure ?? ''), 240);
        const lines = [];
        if (Number.isFinite(payload?.turn)) lines.push(s.turn(payload.turn, payload?.step));
        if (message) lines.push(`${s.error}：${message}`);
        showCard(
          active,
          {
            badge: s.errorBadge,
            head: s.errorHead(taskTitle),
            body: lines.join('\n'),
            footer: s.viewFooter,
            okLabel: s.gotIt,
            okCode: 10,
            hostProcess: active.hostProcess,
          },
          'error',
        );
      },
      { global: true },
    );
    dbg('listener: agent/error');
  } catch (error) {
    dbg(`error listener failed: ${error?.stack ?? error}`);
  }

  // ④ 完成卡片（running → idle 算一轮；失败/中断的轮次不发）
  const runs = new Map();
  try {
    root.on(
      'agent/status',
      (payload) => {
        const agent = payload?.agent;
        if (agent === undefined) return;
        const id = agent?.id ?? 'unknown';
        if (payload?.status === 'running') {
          if (!runs.has(id)) runs.set(id, { startedAt: Date.now(), tokensAtStart: sessionTokens(agent).total });
          return;
        }
        if (payload?.status !== 'idle') return;
        const run = runs.get(id);
        if (run === undefined) return;
        runs.delete(id);
        const active = settings();
        if (!active.notifyDone || lastTurnWasUnclean(agent)) return;
        const s = STRINGS[active.language];
        const tokens = sessionTokens(agent);
        const todo = todoSummary(agent);
        const elapsedMs = Date.now() - run.startedAt;
        const taskTitle = taskTitleOf(agent);
        const summary = lastUserText(agent);
        const turnTokens = formatTokens(Math.max(0, tokens.total - run.tokensAtStart));
        const sessionTotal = formatTokens(tokens.total);
        dbg(`done card (${elapsedMs}ms, autoClose=${active.doneTimeoutSeconds}s)`);
        showCard(
          active,
          {
            badge: s.doneBadge,
            head: s.doneHead(taskTitle),
            body: [
              `${s.content}：${summary.length > 0 ? summary : '—'}`,
              `${s.elapsed}：${formatDuration(active.language, elapsedMs)}`,
              todo === undefined
                ? `${s.remaining}：${s.remainingNone}`
                : `${s.remaining}：${s.remainingValue(todo.pending, todo.doing, todo.done)}`,
              s.tokensLine(turnTokens, sessionTotal),
            ].join('\n'),
            footer: s.viewFooter,
            okLabel: s.ack,
            okCode: 10,
            hostProcess: active.hostProcess,
          },
          'done',
          active.doneTimeoutSeconds,
        );
      },
      { global: true },
    );
    dbg('listener: agent/status');
  } catch (error) {
    dbg(`done listener failed: ${error?.stack ?? error}`);
  }

  // ⑤ 生命周期：插件卸载 / 重载时把还开着的卡片关掉，别留下孤儿窗口。
  try {
    root.effect(() => () => {
      closeAllCards();
    });
    dbg('dispose hook registered');
  } catch (error) {
    dbg(`dispose hook failed: ${error?.message ?? error}`);
  }
}
