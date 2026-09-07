// Chaturbate iPlayer script (iPlayer >= 2.0.0)
// 列出当前在线主播；点击时重新获取最新 HLS，避免旧 session 失效。

const API = 'https://chaturbate.com/api/ts/roomlist/room-list/?gender=f,c,m,t&limit=90&sort_by=\u0070opularity';
const AJAX = 'https://chaturbate.com/get_edge_hls_url_ajax/';
const STORE = 'cb.rooms.v1';

function wait(ms) { return new Promise(r => setTimeout(r, ms)); }
function request(options) {
    return new Promise((resolve, reject) => {
        iNetwork.get(options, (err, res, body) => {
            if (err) reject(err); else resolve(body);
        });
    });
}
function post(options) {
    return new Promise((resolve, reject) => {
        iNetwork.post(options, (err, res, body) => {
            if (err) reject(err); else resolve(body);
        });
    });
}
function parseBody(body) {
    if (typeof body === 'string') return JSON.parse(body);
    return body;
}
function imageOf(room) {
    return room.image_url || room.image ||
        ('https://roomimg.stream.highwebmedia.com/ri/' + room.username + '.jpg');
}
function textOf(room) {
    return (room.room_subject || '公开直播').replace(/\s+/g, ' ').slice(0, 80);
}

async function iPlayerMain(number, index, page) {
    iUI.showHUD('wait', '获取在线主播...');
    try {
        const raw = await request({ url: API, timeout: 20 });
        const obj = parseBody(raw);
        const rooms = (obj.rooms || []).filter(r =>
            r && r.username && r.current_show === 'public' && !r.has_password
        );
        iUI.write(JSON.stringify(rooms), STORE);
        const now = new Date().toLocaleString();
        const data = {
            title: 'Chaturbate 在线主播',
            canPlay: true,
            mutableDuty: true,
            data: rooms.map(r => ({
                name: r.username,
                plat: 'm3u8',
                // address 留空，强制进入点击回调时重新取流
                address: '',
                image: imageOf(r),
                time: textOf(r),
                hot: String(r.num_users || 0),
                type: '2',
                typeInfo: '在线 · ' + now,
                pushNext: false
            }))
        };
        iUI.clearAllHUD();
        iUI.reloadData(data);
        iNotify.notify('Chaturbate', '获取成功', '点击主播即可播放', {
            'open-url': 'iplayer2://script'
        });
    } catch (e) {
        iUI.clearAllHUD();
        iUI.showHUD('error', '获取失败: ' + (e.message || e));
        console.log(e.stack || e);
    }
}

async function iPlayerDidSelectIndexPath(arg) {
    try {
        const raw = iUI.read(STORE);
        const rooms = JSON.parse(raw || '[]');
        const room = rooms[arg.index];
        if (!room || !room.username) return;
        iUI.showHUD('wait', '获取 ' + room.username + ' 最新流...');
        const body = 'room_slug=' + encodeURIComponent(room.username) + '&bandwidth=high';
        const result = await post({
            url: AJAX,
            body: body,
            timeout: 20,
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                'X-Requested-With': 'XMLHttpRequest',
                'Referer': 'https://chaturbate.com/' + room.username + '/'
            }
        });
        const obj = parseBody(result);
        if (obj.room_status !== 'public' || !obj.url) {
            iUI.clearAllHUD();
            iUI.showHUD('error', '主播已下线或不是公开状态');
            return;
        }
        iUI.clearAllHUD();
        // 传官方 llhls master，而不是预先缓存的 chunklist。
        iUI.play(obj.url);
    } catch (e) {
        iUI.clearAllHUD();
        iUI.showHUD('error', '播放失败: ' + (e.message || e));
        console.log(e.stack || e);
    }
}
