/* JO-AIClient 官网交互
   —— 首屏界面示意 + 本地交互演示，全部使用页面内演示数据，不连接任何服务。 */

(function () {
  'use strict';

  var $ = function (sel, root) { return (root || document).querySelector(sel); };
  var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

  /* ============================================================
     1. 首屏界面示意
     ============================================================ */

  var QUESTIONS = {
    '1': {
      text: '用 Dart 写一个快速排序，并解释分区逻辑。',
      session: '1',
      steps: [
        '首次生成回答 → 分支 1',
        '点击“重新生成”→ 分支 2',
        '再次“重新生成”→ 分支 3',
        '用 ◀ 分支 2 / 3 ▶ 切换，右侧消息树同步高亮'
      ]
    },
    '2': {
      text: '把这个页面的 setState 重构为可测试的状态管理方案。',
      session: '2',
      steps: [
        '首次生成回答 → 分支 1（ChangeNotifier，渐进迁移）',
        '“重新生成”→ 分支 2（Riverpod，编译期安全）',
        '“重新生成”→ 分支 3（Bloc，事件驱动）',
        '用 ◀ 分支 2 / 3 ▶ 切换对比三种方案，历史分支不会被覆盖'
      ]
    }
  };

  var TOTAL_BRANCHES = 3;

  var hero = {
    q: '1',
    branch: 2,
    switched: false,
    el: {
      question: $('#heroQuestion'),
      answer: $('#heroAnswer'),
      label: $('#heroBranchLabel'),
      prev: $('#heroPrev'),
      next: $('#heroNext'),
      status: $('#heroStatus'),
      steps: $('#heroSteps'),
      tree: $('#heroTree'),
      sideList: $('#sideList')
    }
  };

  function paintHero(flashMsg) {
    var data = QUESTIONS[hero.q];

    hero.el.question.textContent = data.text;

    $$('.branchpane', hero.el.answer).forEach(function (pane) {
      var on = pane.getAttribute('data-q') === hero.q &&
               Number(pane.getAttribute('data-b')) === hero.branch;
      pane.hidden = !on;
    });

    hero.el.label.textContent = '分支 ' + hero.branch + ' / ' + TOTAL_BRANCHES;
    hero.el.prev.disabled = hero.branch <= 1;
    hero.el.next.disabled = hero.branch >= TOTAL_BRANCHES;

    /* 步骤 */
    var currentIdx = hero.switched ? 4 : hero.branch;
    $$('li', hero.el.steps).forEach(function (li) {
      var idx = Number(li.getAttribute('data-step'));
      var text = $('.s', li);
      if (text && data.steps[idx - 1]) text.textContent = data.steps[idx - 1];
      li.classList.toggle('is-current', idx === currentIdx);
    });

    /* 会话列表 */
    $$('.side__item', hero.el.sideList).forEach(function (li) {
      var sid = li.getAttribute('data-session');
      li.classList.toggle('is-active', sid === data.session);
      li.classList.toggle('is-faded', sid !== '1' && sid !== '2');
    });
    $$('.side__btn', hero.el.sideList).forEach(function (btn) {
      if (btn.tagName === 'BUTTON') {
        btn.setAttribute('aria-pressed', btn.getAttribute('data-q') === hero.q ? 'true' : 'false');
      }
    });

    /* 消息树高亮 */
    var activeLi = $('.tli[data-branch="' + hero.branch + '"]', hero.el.tree);
    $$('.tli', hero.el.tree).forEach(function (li) {
      li.classList.remove('is-active');
      li.classList.remove('on-path');
    });
    ['u1', 'forkA'].forEach(function (id) {
      var n = $('.tli[data-node="' + id + '"]', hero.el.tree);
      if (n) n.classList.add('on-path');
    });
    if (activeLi) {
      activeLi.classList.add('is-active', 'on-path');
      if (hero.branch === 2) {
        ['u2', 'forkB', 'b2a'].forEach(function (id) {
          var n = $('.tli[data-node="' + id + '"]', hero.el.tree);
          if (n) n.classList.add('on-path');
        });
        var leaf = $('.tli[data-node="b2a"]', hero.el.tree);
        if (leaf) leaf.classList.add('is-active');
      }
    }

    /* 当前标记只挂在活动分支上 */
    $$('.tnow', hero.el.tree).forEach(function (tag) {
      var li = tag.closest('.tli');
      var b = li && li.getAttribute('data-branch');
      var n = li && li.getAttribute('data-node');
      tag.hidden = !((b && Number(b) === hero.branch) || (n === 'b2a' && hero.branch === 2));
    });

    if (flashMsg) setStatus(flashMsg, true);
  }

  var statusTimer = null;
  function setStatus(msg, flash) {
    hero.el.status.textContent = msg;
    hero.el.status.classList.toggle('is-flash', !!flash);
    if (flash) {
      window.clearTimeout(statusTimer);
      statusTimer = window.setTimeout(function () {
        hero.el.status.classList.remove('is-flash');
      }, 2600);
    }
  }

  function setBranch(next, viaArrow) {
    var b = Math.min(TOTAL_BRANCHES, Math.max(1, next));
    if (b === hero.branch) return;
    hero.branch = b;
    if (viaArrow) hero.switched = true;
    paintHero(viaArrow ? '已切换到分支 ' + b + '。对话区只渲染当前活动分支，右侧消息树同步高亮这条路径。' : null);
  }

  function setQuestion(q) {
    if (!QUESTIONS[q] || q === hero.q) return;
    hero.q = q;
    hero.switched = false;
    hero.branch = 2;
    $$('.chat__switch .seg__b').forEach(function (b) {
      var on = b.getAttribute('data-q') === q;
      b.classList.toggle('is-on', on);
      b.setAttribute('aria-pressed', on ? 'true' : 'false');
    });
    paintHero('已切换示例问题。这个会话在同一位置也有 3 个分支，都是重新生成留下的。');
  }

  if (hero.el.answer) {
    hero.el.prev.addEventListener('click', function () { setBranch(hero.branch - 1, true); });
    hero.el.next.addEventListener('click', function () { setBranch(hero.branch + 1, true); });

    $$('.chat__switch .seg__b').forEach(function (b) {
      b.addEventListener('click', function () { setQuestion(b.getAttribute('data-q')); });
    });

    /* 侧栏前两条会话同样可以切换示例问题 */
    $$('.side__btn[data-q]', hero.el.sideList).forEach(function (btn) {
      btn.addEventListener('click', function () { setQuestion(btn.getAttribute('data-q')); });
    });

    /* 消息操作菜单 */
    var menuBtn = $('#heroMenuBtn');
    var menu = $('#heroMenu');
    var MENU_COPY = {
      'regen': '示意：“重新生成”会在同一位置追加一个新分支，已有分支不会被覆盖。',
      'delete-after': '示意：“删除后续”按树结构删除当前节点之后、当前活动分支上的节点，其他分支不受影响。',
      'delete-branch': '示意：“删除当前分支”只移除这一条分支，同一分叉点上的其他分支保留。',
      'continue': '示意：“从历史消息继续对话”以该节点为分叉锚点新建分支，原有分支继续保留在树上。'
    };

    function closeMenu(refocus) {
      if (menu.hidden) return;
      menu.hidden = true;
      menuBtn.setAttribute('aria-expanded', 'false');
      if (refocus) menuBtn.focus();
    }

    menuBtn.addEventListener('click', function () {
      var open = menu.hidden;
      menu.hidden = !open;
      menuBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
      if (open) {
        var first = $('button', menu);
        if (first) first.focus();
      }
    });

    menu.addEventListener('click', function (e) {
      var btn = e.target.closest('button[data-act]');
      if (!btn) return;
      setStatus(MENU_COPY[btn.getAttribute('data-act')] || '', true);
      closeMenu(true);
    });

    document.addEventListener('click', function (e) {
      if (!menu.hidden && !menu.contains(e.target) && e.target !== menuBtn) closeMenu(false);
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') closeMenu(false);
    });

    paintHero(null);
  }

  /* ============================================================
     2. 导航当前区块标记
     ============================================================ */

  var navLinks = $$('.site-nav a');
  var sections = navLinks
    .map(function (a) { return document.getElementById(a.getAttribute('href').slice(1)); })
    .filter(Boolean);

  if ('IntersectionObserver' in window && sections.length) {
    var visible = {};
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) { visible[en.target.id] = en.isIntersecting; });
      var activeId = null;
      for (var i = 0; i < sections.length; i++) {
        if (visible[sections[i].id]) { activeId = sections[i].id; break; }
      }
      navLinks.forEach(function (a) {
        var on = a.getAttribute('href') === '#' + activeId;
        if (on) a.setAttribute('aria-current', 'true');
        else a.removeAttribute('aria-current');
      });
    }, { rootMargin: '-45% 0px -50% 0px', threshold: 0 });
    sections.forEach(function (s) { io.observe(s); });
  }

  /* ============================================================
     3. 交互演示
     ============================================================ */

  var stage = $('#demoStage');
  var stepsEl = $('#demoSteps');
  var countEl = $('#demoCount');
  var prevBtn = $('#demoPrev');
  var nextBtn = $('#demoNext');
  var announceEl = $('#demoAnnounce');
  if (!stage) return;

  /* ---- 示例 A 的数据 ---- */

  var A_QUESTION = '用 Dart 写一个快速排序，并解释分区逻辑。';

  var A_BRANCHES = [
    {
      tag: '首次生成 · 14:02',
      html: '<pre><code>List&lt;int&gt; quickSort(List&lt;int&gt; a) {\n' +
            '  if (a.length &lt;= 1) return a;\n' +
            '  final pivot = a[a.length ~/ 2];\n' +
            '  final lo = &lt;int&gt;[], eq = &lt;int&gt;[], hi = &lt;int&gt;[];\n' +
            '  for (final x in a) {\n' +
            '    if (x &lt; pivot) lo.add(x);\n' +
            '    else if (x &gt; pivot) hi.add(x);\n' +
            '    else eq.add(x);\n' +
            '  }\n' +
            '  return [...quickSort(lo), ...eq, ...quickSort(hi)];\n' +
            '}</code></pre>' +
            '<p>三路分区：小于 / 等于 / 大于各一段，等于段一次落位。直观，但每层都新建列表。</p>'
    },
    {
      tag: '重新生成 · 14:05',
      html: '<pre><code>void quickSort(List&lt;int&gt; a, [int lo = 0, int hi = -1]) {\n' +
            '  hi = hi &lt; 0 ? a.length - 1 : hi;\n' +
            '  if (lo &gt;= hi) return;\n' +
            '  final pivot = a[hi];\n' +
            '  var i = lo;\n' +
            '  for (var j = lo; j &lt; hi; j++) {\n' +
            '    if (a[j] &lt; pivot) {\n' +
            '      final t = a[i]; a[i] = a[j]; a[j] = t; i++;\n' +
            '    }\n' +
            '  }\n' +
            '  final t = a[i]; a[i] = a[hi]; a[hi] = t;\n' +
            '  quickSort(a, lo, i - 1);\n' +
            '  quickSort(a, i + 1, hi);\n' +
            '}</code></pre>' +
            '<p>Lomuto 原地分区：<code>i</code> 左侧是已确认的小于区，扫描结束后把基准换到 <code>i</code>，基准即落在最终位置。</p>'
    },
    {
      tag: '重新生成 · 14:09',
      html: '<p>先说结论：生产代码更推荐直接 <code>list.sort()</code>。若要自己实现，注意三点：</p>' +
            '<p><strong>基准选择</strong>——固定取末尾在已排序输入上退化为 O(n²)；<strong>相等元素</strong>——三路分区收益明显；' +
            '<strong>递归深度</strong>——先递归短侧、长侧改循环，可压到 O(log n)。</p>'
    }
  ];

  var A_STEPS = [
    {
      title: '首次生成回答',
      note: '提出问题后模型给出第一版回答，此时该位置只有一个分支，分支控件不可切换。',
      branches: 1, active: 1,
      flash: '消息树：用户提问 → 分叉点 A（1 个分支）。'
    },
    {
      title: '点击“重新生成”，产生分支 2',
      note: '重新生成不覆盖原回答，而是在同一位置追加一个新分支。分叉点 A 现在有 2 个子节点，活动分支指向新的分支 2。',
      branches: 2, active: 2,
      flash: '分支 1 仍然完整保存在 SQLite 中，随时可以切回去。'
    },
    {
      title: '再次重新生成，产生分支 3',
      note: '第三次生成继续追加分支。分叉点 A 现在有 3 个子节点，界面依旧只渲染当前活动分支。',
      branches: 3, active: 3,
      flash: '三个分支各自带创建时间与来源标记（首次生成 / 重新生成）。'
    },
    {
      title: '用 ◀ 分支 2 / 3 ▶ 切换',
      note: '点击分支控件的左右箭头，对话区内容随之替换，右侧消息树同步把高亮移到对应分支。可以直接在左侧舞台里点箭头试试。',
      branches: 3, active: 2,
      flash: '切换只改变“显示哪一条”，不修改任何分支数据。'
    }
  ];

  /* ---- 示例 B 的数据 ---- */

  var B_ROOT_Q = '给这个查询接口加一层缓存，别每次都打数据库。';

  var B_TOP = [
    {
      id: 1, time: '14:02', tag: '首次生成',
      html: '<p><strong>方案一：内存 Map。</strong>用 <code>Map&lt;String, dynamic&gt;</code> 存查询结果，写操作后手动清掉相关键。' +
            '实现最快，但没有容量上限，进程重启即失效。</p>'
    },
    {
      id: 2, time: '14:05', tag: '重新生成',
      html: '<p><strong>方案二：TTL + LRU。</strong>缓存项带过期时间，配合容量上限做 LRU 淘汰，命中与失效都有明确边界，适合读多写少的查询接口。</p>',
      follow: {
        q: 'TTL 到期那一刻，并发请求会不会全部打到数据库？',
        kids: [
          { id: 1, time: '14:08', tag: '首次生成', html: '<p><strong>互斥锁 / single-flight。</strong>同一键只放一个请求回源，其余等待结果，避免缓存击穿。</p>' },
          { id: 2, time: '14:11', tag: '编辑问题后重发', html: '<p><strong>逻辑过期 + 后台刷新。</strong>缓存永不物理过期，读到过期项时返回旧值并异步刷新，响应延迟稳定。</p>' }
        ]
      }
    },
    {
      id: 3, time: '14:06', tag: '编辑问题后重发',
      html: '<p><strong>方案三：交给 HTTP 缓存。</strong>接口返回 <code>Cache-Control</code> 与 <code>ETag</code>，由客户端和中间层缓存，服务端只处理条件请求。</p>'
    }
  ];

  var B_STEPS = [
    {
      title: '上游原版导入：分叉被拍平成单链',
      note: '同一段对话在上游原版导入后，所有消息被排成一条链。原本“同一位置的三个备选回答”变成了前后相连的三条消息，分叉关系无处存放。',
      render: renderB1
    },
    {
      title: 'JO-AIClient 导入：按树完整重建',
      note: 'Chatbox 1.22 以下走树形 JSON，1.22 起走 ZIP 备份，两条路都按消息树重建：分叉消息、嵌套分支、分支创建时间、选中路径全部保留。',
      render: renderB2
    },
    {
      title: '导入后仍可切换分支',
      note: '导入不是终点。重建出来的树和原生会话没有区别，分支控件可以直接切换，看到的内容与原始对话一致。点下面的箭头试试。',
      render: renderB3
    }
  ];

  function listRow(text, cls, mark) {
    return '<li class="' + (cls || '') + '"><span class="mk">' + (mark || '·') + '</span><span>' + text + '</span></li>';
  }

  function renderB1() {
    var chain = [
      { who: '你', text: B_ROOT_Q, lost: false },
      { who: 'JO-AIClient', text: '方案一：内存 Map。用 Map 存查询结果，写操作后手动清掉相关键。', lost: false },
      { who: 'JO-AIClient', text: '方案二：TTL + LRU。缓存项带过期时间，配合容量上限做 LRU 淘汰。', lost: true },
      { who: 'JO-AIClient', text: '方案三：交给 HTTP 缓存。接口返回 Cache-Control 与 ETag。', lost: true },
      { who: '你', text: 'TTL 到期那一刻，并发请求会不会全部打到数据库？', lost: false },
      { who: 'JO-AIClient', text: '互斥锁 / single-flight。同一键只放一个请求回源，其余等待结果。', lost: true },
      { who: 'JO-AIClient', text: '逻辑过期 + 后台刷新。读到过期项时返回旧值并异步刷新。', lost: true }
    ];

    var msgs = chain.map(function (m) {
      return '<div class="dmsg' + (m.who === '你' ? ' dmsg--user' : ' dmsg--ai') + '">' +
               '<span class="dmsg__who">' + m.who + '</span>' +
               '<div class="dmsg__b"><p>' + m.text + '</p></div>' +
               (m.lost
                 ? '<div class="dmsg__meta"><span class="tag tag--lost">✕ 分叉丢失</span><span class="tag">被排入单链</span></div>'
                 : '') +
             '</div>';
    }).join('');

    return '<div class="stage__cols">' +
             '<div class="dchat">' + msgs + '</div>' +
             '<div class="dpanel">' +
               '<h4 class="dpanel__h">这段结果里丢掉的</h4>' +
               '<ul class="dlist">' +
                 listRow('分叉锚点：看不出第 2、3、4 条其实是同一位置的备选', 'is-lost', '✕') +
                 listRow('分支创建时间：14:02 / 14:05 / 14:06 的顺序无处存放', 'is-lost', '✕') +
                 listRow('选中路径：原对话里用户实际继续的是哪一条', 'is-lost', '✕') +
                 listRow('嵌套分支：第二处分叉同样被拍平', 'is-lost', '✕') +
               '</ul>' +
             '</div>' +
           '</div>' +
           '<p class="stage__flash">导入完成后，这段对话在应用里就只有一条线，无法再切回其他备选回答。</p>';
  }

  function bTreeHtml(activeTop, activeNested) {
    var kids = B_TOP.map(function (b) {
      var isActive = b.id === activeTop;
      var inner = '<span class="trow"><span class="tdot"></span><span class="tlabel">分支 ' + b.id + '</span>' +
                  '<span class="tcount">' + b.time + '</span>' +
                  (isActive ? '<span class="tnow">当前</span>' : '') + '</span>';
      if (b.follow) {
        var gk = b.follow.kids.map(function (k) {
          var kOn = isActive && k.id === activeNested;
          return '<li class="tli' + (kOn ? ' is-active on-path' : '') + '" data-bk="' + k.id + '">' +
                   '<span class="trow"><span class="tdot"></span><span class="tlabel">分支 ' + k.id + '</span>' +
                   '<span class="tcount">' + k.time + '</span>' +
                   (kOn ? '<span class="tnow">当前</span>' : '') + '</span>' +
                 '</li>';
        }).join('');
        inner += '<ul>' +
                   '<li class="tli' + (isActive ? ' on-path' : '') + '">' +
                     '<span class="trow"><span class="tdot tdot--user"></span><span class="tlabel">用户追问</span></span>' +
                     '<ul><li class="tli' + (isActive ? ' on-path' : '') + '">' +
                       '<span class="trow"><span class="tdot tdot--fork"></span><span class="tlabel">分叉点 B</span><span class="tcount">2</span></span>' +
                       '<ul>' + gk + '</ul>' +
                     '</li></ul>' +
                   '</li>' +
                 '</ul>';
      }
      return '<li class="tli' + (isActive ? ' is-active on-path' : '') + '" data-bt="' + b.id + '">' + inner + '</li>';
    }).join('');

    return '<div class="tree">' +
             '<ul><li class="tli on-path">' +
               '<span class="trow"><span class="tdot tdot--user"></span><span class="tlabel">用户提问</span></span>' +
               '<ul><li class="tli on-path">' +
                 '<span class="trow"><span class="tdot tdot--fork"></span><span class="tlabel">分叉点 A</span><span class="tcount">3</span></span>' +
                 '<ul>' + kids + '</ul>' +
               '</li></ul>' +
             '</li></ul>' +
           '</div>';
  }

  function renderB2() {
    return '<div class="stage__cols">' +
             '<div class="dpanel dpanel--plain">' +
               '<h4 class="dpanel__h">重建后的消息树</h4>' +
               bTreeHtml(2, 1) +
             '</div>' +
             '<div class="dpanel">' +
               '<h4 class="dpanel__h">保留下来的信息</h4>' +
               '<ul class="kv">' +
                 '<li><span class="k">分叉消息</span><span class="v">已保留</span></li>' +
                 '<li><span class="k">嵌套分支</span><span class="v">已保留</span></li>' +
                 '<li><span class="k">分支创建时间</span><span class="v">已保留</span></li>' +
                 '<li><span class="k">选中路径</span><span class="v">已保留</span></li>' +
                 '<li><span class="k">导入模式</span><span class="v">合并 / 覆盖</span></li>' +
               '</ul>' +
               '<p class="dpanel__p">合并模式保留本地内容，覆盖模式只定点替换对应导入会话。</p>' +
             '</div>' +
           '</div>' +
           '<p class="stage__flash">两处分叉、五个回答版本、各自的时间戳，导入后一个都不少。</p>';
  }

  function renderB3() {
    var b = B_TOP.filter(function (x) { return x.id === state.bActive; })[0] || B_TOP[1];
    var nested = '';

    if (b.follow) {
      var k = b.follow.kids.filter(function (x) { return x.id === state.bNested; })[0] || b.follow.kids[0];
      nested =
        '<div class="dmsg dmsg--user">' +
          '<span class="dmsg__who">你</span>' +
          '<div class="dmsg__b"><p>' + b.follow.q + '</p></div>' +
        '</div>' +
        '<div class="dmsg dmsg--ai is-live">' +
          '<span class="dmsg__who">JO-AIClient</span>' +
          '<div class="dmsg__b">' + k.html + '</div>' +
          '<div class="dmsg__meta">' +
            branchCtl('bNested', b.follow.kids.length, k.id) +
            '<span class="tag">' + k.tag + ' · ' + k.time + '</span>' +
            '<span class="tag tag--gold">嵌套分支</span>' +
          '</div>' +
        '</div>';
    } else {
      nested = '<p class="stage__flash">该分支在原始对话中没有后续消息——这也是被保留下来的事实，而不是导入时补出来的。</p>';
    }

    return '<div class="stage__cols">' +
             '<div class="dchat">' +
               '<div class="dmsg dmsg--user">' +
                 '<span class="dmsg__who">你</span>' +
                 '<div class="dmsg__b"><p>' + B_ROOT_Q + '</p></div>' +
               '</div>' +
               '<div class="dmsg dmsg--ai is-live">' +
                 '<span class="dmsg__who">JO-AIClient</span>' +
                 '<div class="dmsg__b">' + b.html + '</div>' +
                 '<div class="dmsg__meta">' +
                   branchCtl('bTop', B_TOP.length, b.id) +
                   '<span class="tag">' + b.tag + ' · ' + b.time + '</span>' +
                   '<span class="tag tag--gold">导入的分支</span>' +
                 '</div>' +
               '</div>' +
               nested +
             '</div>' +
             '<div class="dpanel">' +
               '<h4 class="dpanel__h">消息树</h4>' +
               bTreeHtml(b.id, state.bNested) +
             '</div>' +
           '</div>';
  }

  function branchCtl(key, total, active) {
    return '<span class="branchctl" data-ctl="' + key + '">' +
             '<button type="button" class="branchctl__b" data-dir="-1" aria-label="上一个分支"' + (active <= 1 ? ' disabled' : '') + '>' +
               '<svg viewBox="0 0 12 12" width="11" height="11" aria-hidden="true" focusable="false"><path d="M7.5 2 3.5 6l4 4" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>' +
             '</button>' +
             '<span class="branchctl__label">分支 ' + active + ' / ' + total + '</span>' +
             '<button type="button" class="branchctl__b" data-dir="1" aria-label="下一个分支"' + (active >= total ? ' disabled' : '') + '>' +
               '<svg viewBox="0 0 12 12" width="11" height="11" aria-hidden="true" focusable="false"><path d="M4.5 2l4 4-4 4" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>' +
             '</button>' +
           '</span>';
  }

  /* ---- 示例 A 的舞台 ---- */

  function demoTreeHtml(count, active) {
    var items = '';
    for (var i = 1; i <= count; i++) {
      items += '<li class="tli' + (i === active ? ' is-active on-path' : '') + '">' +
                 '<span class="trow"><span class="tdot"></span><span class="tlabel">分支 ' + i + '</span>' +
                 (i === active ? '<span class="tnow">当前</span>' : '') + '</span>' +
               '</li>';
    }
    return '<div class="tree"><ul><li class="tli on-path">' +
             '<span class="trow"><span class="tdot tdot--user"></span><span class="tlabel">用户提问</span></span>' +
             '<ul><li class="tli on-path">' +
               '<span class="trow"><span class="tdot tdot--fork"></span><span class="tlabel">分叉点 A</span><span class="tcount">' + count + '</span></span>' +
               '<ul>' + items + '</ul>' +
             '</li></ul>' +
           '</li></ul></div>';
  }

  function renderA() {
    var st = A_STEPS[state.step];
    var b = A_BRANCHES[state.aActive - 1];
    return '<div class="stage__cols">' +
             '<div class="dchat">' +
               '<div class="dmsg dmsg--user">' +
                 '<span class="dmsg__who">你</span>' +
                 '<div class="dmsg__b"><p>' + A_QUESTION + '</p></div>' +
               '</div>' +
               '<div class="dmsg dmsg--ai is-live">' +
                 '<span class="dmsg__who">JO-AIClient</span>' +
                 '<div class="dmsg__b">' + b.html + '</div>' +
                 '<div class="dmsg__meta">' +
                   branchCtl('a', st.branches, state.aActive) +
                   '<span class="tag">' + b.tag + '</span>' +
                   (state.aActive > 1 ? '<span class="tag tag--gold">重新生成产生</span>' : '') +
                 '</div>' +
               '</div>' +
               '<p class="stage__flash">' + st.flash + '</p>' +
             '</div>' +
             '<div class="dpanel">' +
               '<h4 class="dpanel__h">消息树</h4>' +
               demoTreeHtml(st.branches, state.aActive) +
               '<p class="dpanel__p">界面默认只显示当前活动分支。</p>' +
             '</div>' +
           '</div>';
  }

  /* ---- 演示状态机 ---- */

  var state = { demo: 'a', step: 0, aActive: 1, bActive: 2, bNested: 1 };

  function currentSteps() { return state.demo === 'a' ? A_STEPS : B_STEPS; }

  function focusAfter(container, selector) {
    var el = selector ? container.querySelector(selector) : null;
    if (el && !el.disabled) { el.focus(); return true; }
    return false;
  }

  function paintDemo(announce) {
    var steps = currentSteps();
    var st = steps[state.step];

    if (state.demo === 'a') {
      var bound = Math.min(state.aActive, st.branches);
      if (bound !== state.aActive) state.aActive = bound;
    }

    stage.innerHTML =
      '<div class="stage__head">' +
        '<span class="stage__k">' + (state.demo === 'a' ? '示例 A' : '示例 B') + ' · 步骤 ' + (state.step + 1) + ' / ' + steps.length + '</span>' +
        '<h4 class="stage__t">' + st.title + '</h4>' +
      '</div>' +
      '<p class="stage__note">' +
        (state.demo === 'a'
          ? '演示内容：<code>' + A_QUESTION + '</code>　' + st.note
          : '演示内容：<code>假设从 Chatbox 导入一段含分叉的对话。</code>　' + st.note) +
      '</p>' +
      (state.demo === 'a' ? renderA() : st.render());

    /* 步骤列表 */
    stepsEl.innerHTML = steps.map(function (s, i) {
      var cls = i === state.step ? 'is-current' : (i < state.step ? 'is-done' : '');
      return '<li class="' + cls + '">' +
               '<button type="button" data-goto="' + i + '"' + (i === state.step ? ' aria-current="step"' : '') + '>' +
                 '<span class="sn">' + (i + 1) + '</span><span>' + s.title + '</span>' +
               '</button>' +
             '</li>';
    }).join('');

    countEl.textContent = (state.step + 1) + ' / ' + steps.length;
    prevBtn.disabled = state.step === 0;
    nextBtn.disabled = state.step === steps.length - 1;
    nextBtn.textContent = state.step === steps.length - 1 ? '已是最后一步' : '下一步';

    if (announceEl) {
      announceEl.textContent = announce ||
        ('步骤 ' + (state.step + 1) + '，共 ' + steps.length + ' 步：' + st.title);
    }
  }

  function gotoStep(i) {
    var steps = currentSteps();
    state.step = Math.max(0, Math.min(steps.length - 1, i));
    if (state.demo === 'a') {
      state.aActive = A_STEPS[state.step].active;
    }
    paintDemo();
  }

  function switchDemo(which) {
    if (which === state.demo) return;
    state.demo = which;
    state.step = 0;
    state.aActive = A_STEPS[0].active;
    $$('.demo__picker .seg__b').forEach(function (b) {
      var on = b.getAttribute('data-demo') === which;
      b.classList.toggle('is-on', on);
      b.setAttribute('aria-pressed', on ? 'true' : 'false');
    });
    paintDemo();
  }

  $$('.demo__picker .seg__b').forEach(function (b) {
    b.addEventListener('click', function () { switchDemo(b.getAttribute('data-demo')); });
  });

  prevBtn.addEventListener('click', function () { gotoStep(state.step - 1); });
  nextBtn.addEventListener('click', function () { gotoStep(state.step + 1); });

  stepsEl.addEventListener('click', function (e) {
    var btn = e.target.closest('button[data-goto]');
    if (!btn) return;
    var i = Number(btn.getAttribute('data-goto'));
    gotoStep(i);
    focusAfter(stepsEl, 'button[data-goto="' + i + '"]');
  });

  /* 舞台内的分支控件 */
  stage.addEventListener('click', function (e) {
    var btn = e.target.closest('.branchctl__b');
    if (!btn || btn.disabled) return;
    var ctl = btn.closest('.branchctl');
    var key = ctl.getAttribute('data-ctl');
    var dir = Number(btn.getAttribute('data-dir'));
    var active = 0;
    var total = 0;

    if (key === 'a') {
      total = A_STEPS[state.step].branches;
      state.aActive = Math.max(1, Math.min(total, state.aActive + dir));
      active = state.aActive;
    } else if (key === 'bTop') {
      total = B_TOP.length;
      state.bActive = Math.max(1, Math.min(total, state.bActive + dir));
      state.bNested = 1;
      active = state.bActive;
    } else if (key === 'bNested') {
      var cur = B_TOP.filter(function (x) { return x.id === state.bActive; })[0];
      total = cur && cur.follow ? cur.follow.kids.length : 1;
      state.bNested = Math.max(1, Math.min(total, state.bNested + dir));
      active = state.bNested;
    }

    paintDemo('已切换到分支 ' + active + ' / ' + total + '，消息树高亮同步移动。');

    /* 重新渲染后把焦点还给同一侧的箭头，箭头到边界时改聚焦另一侧 */
    if (!focusAfter(stage, '.branchctl[data-ctl="' + key + '"] .branchctl__b[data-dir="' + dir + '"]')) {
      focusAfter(stage, '.branchctl[data-ctl="' + key + '"] .branchctl__b[data-dir="' + (-dir) + '"]');
    }
  });

  paintDemo();
})();
