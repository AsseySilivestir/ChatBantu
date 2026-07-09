// ════════════════════════════════════════════════════════════════════
//  ChatBantu v2 — Social Network Backend (Real-Time)
//  ────────────────────────────────────────────────────────────────────
//  Pure Bantu Language + Sua Framework + SQLite
//  Features:
//    • User registration & login (token-based, no external deps)
//    • Social feed: posts, likes, comments
//    • Friendships: follow / unfollow
//    • Real-time 1-to-1 chat via WebSocket relay (ZERO polling)
//    • Presence: online/offline via WebSocket connections
//    • WebRTC signaling: offer/answer/ICE via WebSocket (real-time)
//    • Embedded TURN server (Bantu v1.3.0) for NAT traversal
//    • Live notifications
//
//  Architecture:
//    1. Bantu HTTP server (this file) — REST API + static files
//    2. wsrelay (wsrelay.c) — WebSocket relay on port 8081
//       Clients connect to wsrelay for all real-time events.
//       The Bantu server forwards messages to wsrelay via HTTP.
//    3. Bantu embedded TURN on port 3478 (v1.3.0)
//
//  Run:     bantu run server.b
//  Relay:   ./wsrelay 8081 ./chatbantu.db
//  HTTP:    http://0.0.0.0:$PORT
//  DB:      /data/chatbantu.db (Render volume) or ./chatbantu.db (local)
// ════════════════════════════════════════════════════════════════════

print "═══════════════════════════════════════════";
print "  ChatBantu v2 — Real-Time Social Network";
print "  Pure Bantu + Sua + SQLite + WebSocket";
print "═══════════════════════════════════════════";

// ─── Configuration ───────────────────────────────────────────────────
string $envPort = env("PORT");
if (!$envPort) { $envPort = "8080"; }
string $relayPort = "8081";
string $relayUrl = "http://127.0.0.1:" + $relayPort;
string $dbPath = "/data/chatbantu.db";

// Probe persistent volume; fall back to local file
dict $probe = sua.sqlite.open($dbPath);
if (!$probe.connected) {
    $dbPath = "chatbantu.db";
    print "[INFO] /data not writable, using local: " + $dbPath;
} else {
    print "[INFO] Using persistent volume: " + $dbPath;
}

print "[INFO] Opening SQLite at " + $dbPath;
dict $conn = sua.sqlite.open($dbPath);
if (!$conn.connected) {
    print "[ERROR] Cannot open SQLite — aborting.";
    exit(1);
}
print "[OK] Connected to SQLite.";

// ─── Schema ──────────────────────────────────────────────────────────
sua.sqlite.exec("PRAGMA journal_mode=WAL;");
sua.sqlite.exec("PRAGMA foreign_keys=ON;");

sua.sqlite.exec("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, password TEXT NOT NULL, display_name TEXT NOT NULL, bio TEXT DEFAULT '', avatar TEXT DEFAULT '', token TEXT, last_seen INTEGER DEFAULT 0, created_at TEXT DEFAULT (datetime('now')));");

sua.sqlite.exec("CREATE TABLE IF NOT EXISTS follows (id INTEGER PRIMARY KEY AUTOINCREMENT, follower_id INTEGER NOT NULL, followee_id INTEGER NOT NULL, created_at TEXT DEFAULT (datetime('now')), UNIQUE(follower_id, followee_id));");

sua.sqlite.exec("CREATE TABLE IF NOT EXISTS posts (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, body TEXT NOT NULL, image TEXT DEFAULT '', created_at TEXT DEFAULT (datetime('now')), FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);");
sua.sqlite.exec("CREATE INDEX IF NOT EXISTS idx_posts_user ON posts(user_id);");
sua.sqlite.exec("CREATE INDEX IF NOT EXISTS idx_posts_created ON posts(created_at DESC);");

sua.sqlite.exec("CREATE TABLE IF NOT EXISTS likes (id INTEGER PRIMARY KEY AUTOINCREMENT, post_id INTEGER NOT NULL, user_id INTEGER NOT NULL, created_at TEXT DEFAULT (datetime('now')), UNIQUE(post_id, user_id), FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE, FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);");
sua.sqlite.exec("CREATE INDEX IF NOT EXISTS idx_likes_post ON likes(post_id);");

sua.sqlite.exec("CREATE TABLE IF NOT EXISTS comments (id INTEGER PRIMARY KEY AUTOINCREMENT, post_id INTEGER NOT NULL, user_id INTEGER NOT NULL, body TEXT NOT NULL, created_at TEXT DEFAULT (datetime('now')), FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE, FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);");
sua.sqlite.exec("CREATE INDEX IF NOT EXISTS idx_comments_post ON comments(post_id);");

// Conversations are 1-to-1: a sorted pair (a,b) is the conversation key.
sua.sqlite.exec("CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, from_id INTEGER NOT NULL, to_id INTEGER NOT NULL, body TEXT NOT NULL, created_at TEXT DEFAULT (datetime('now')), delivered INTEGER DEFAULT 0, FOREIGN KEY (from_id) REFERENCES users(id) ON DELETE CASCADE, FOREIGN KEY (to_id) REFERENCES users(id) ON DELETE CASCADE);");
sua.sqlite.exec("CREATE INDEX IF NOT EXISTS idx_messages_to ON messages(to_id, delivered, id);");
sua.sqlite.exec("CREATE INDEX IF NOT EXISTS idx_messages_pair ON messages(from_id, to_id, id);");

sua.sqlite.exec("CREATE TABLE IF NOT EXISTS notifications (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, type TEXT NOT NULL, body TEXT NOT NULL, link TEXT DEFAULT '', is_read INTEGER DEFAULT 0, created_at TEXT DEFAULT (datetime('now')), FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE);");
sua.sqlite.exec("CREATE INDEX IF NOT EXISTS idx_notif_user ON notifications(user_id, is_read, id);");

print "[OK] Schema ready (users, follows, posts, likes, comments, messages, notifications).";

// ─── Seed an admin user if empty ─────────────────────────────────────
list $u = sua.sqlite.query("SELECT COUNT(*) AS n FROM users;");
if (num($u[0].n) == 0) {
    sua.sqlite.exec("INSERT INTO users (username, password, display_name, bio) VALUES ('silivestir', 'bantu123', 'Silivestir', 'Creator of ChatBantu. Building African tech with Bantu + Sua.');");
    sua.sqlite.exec("INSERT INTO users (username, password, display_name, bio) VALUES ('alice', 'alice123', 'Alice Mwangi', 'Designer & photographer from Nairobi.');");
    sua.sqlite.exec("INSERT INTO users (username, password, display_name, bio) VALUES ('bob', 'bob123', 'Bob Otieno', 'Software engineer. Coffee enthusiast.');");
    sua.sqlite.exec("INSERT INTO follows (follower_id, followee_id) VALUES (1, 2);");
    sua.sqlite.exec("INSERT INTO follows (follower_id, followee_id) VALUES (1, 3);");
    sua.sqlite.exec("INSERT INTO follows (follower_id, followee_id) VALUES (2, 1);");
    sua.sqlite.exec("INSERT INTO posts (user_id, body) VALUES (1, 'Welcome to ChatBantu v2 — real-time social networking powered by Bantu v1.3.0 with embedded TURN, WebSocket signaling, and zero polling. Video calls, voice calls, and chat are all instant now.');");
    sua.sqlite.exec("INSERT INTO posts (user_id, body) VALUES (2, 'Just shipped a new design portfolio. Loving how Bantu makes backend code feel familiar and clean.');");
    sua.sqlite.exec("INSERT INTO posts (user_id, body) VALUES (3, 'Coffee + code = happiness. Working on some new Bantu examples today.');");
    sua.sqlite.exec("INSERT INTO likes (post_id, user_id) VALUES (1, 2);");
    sua.sqlite.exec("INSERT INTO likes (post_id, user_id) VALUES (1, 3);");
    sua.sqlite.exec("INSERT INTO likes (post_id, user_id) VALUES (2, 1);");
    sua.sqlite.exec("INSERT INTO comments (post_id, user_id, body) VALUES (1, 2, 'This is amazing! Real-time everything now!');");
    sua.sqlite.exec("INSERT INTO comments (post_id, user_id, body) VALUES (1, 3, 'Bantu v1.3.0 is going to change the game for African developers.');");
    print "[OK] Seeded 3 users + 3 posts + likes + comments.";
}

// ════════════════════════════════════════════════════════════════════
//  HELPERS
// ════════════════════════════════════════════════════════════════════

// Escape single quotes for SQL string literals.
def esc($s) {
    if (!$s) { return ""; }
    string $out = "";
    string $c = "";
    number $i = 0;
    while ($i < len($s)) {
        $c = $s[$i];
        if ($c == "'") {
            $out = $out + "''";
        } else {
            $out = $out + $c;
        }
        $i = $i + 1;
    }
    return $out;
}

// Generate a pseudo-random hex token (32 chars = 128 bits).
def newToken() {
    string $t = "";
    string $hex = "0123456789abcdef";
    number $i = 0;
    while ($i < 32) {
        number $r = random(15);
        $t = $t + $hex[$r];
        $i = $i + 1;
    }
    return $t;
}

// Current epoch milliseconds.
def nowMs() {
    return clock();
}

// Look up the user by the Bearer token in $req.headers.authorization.
def authUser($req) {
    dict $hdrs = $req.headers;
    string $auth = "";
    if ($hdrs.authorization) { $auth = $hdrs.authorization; }
    if (len($auth) < 8) { return null; }
    string $tok = substr($auth, 7);
    if (len($tok) < 8) { return null; }

    list $rows = sua.sqlite.query(
        "SELECT id, username, display_name FROM users WHERE token = '" + esc($tok) + "';"
    );
    if (len($rows) == 0) { return null; }
    dict $u = {
        "id": num($rows[0].id),
        "username": $rows[0].username,
        "displayName": $rows[0].display_name
    };
    sua.sqlite.exec("UPDATE users SET last_seen = " + str(nowMs()) + " WHERE id = " + str($u.id) + ";");
    return $u;
}

// Build a "safe" user dict (no password / token leak).
def publicUser($row) {
    dict $u = {
        "id": num($row.id),
        "username": $row.username,
        "displayName": $row.display_name,
        "bio": $row.bio,
        "avatar": $row.avatar
    };
    return $u;
}

// Build a post dict from a SQL row + optional counts.
def postFromRow($row, $likeCount, $commentCount) {
    dict $p = {
        "id": num($row.id),
        "userId": num($row.user_id),
        "authorName": $row.author_name,
        "authorUsername": $row.author_username,
        "body": $row.body,
        "image": $row.image,
        "createdAt": $row.created_at,
        "likes": num($likeCount),
        "comments": num($commentCount)
    };
    return $p;
}

// Send a notification to $toUserId.
def notify($toUserId, $type, $body, $link) {
    sua.sqlite.exec(
        "INSERT INTO notifications (user_id, type, body, link) VALUES (" +
        str($toUserId) + ", '" + esc($type) + "', '" + esc($body) + "', '" + esc($link) + "');"
    );
}

// Forward a real-time event to a user via the WebSocket relay.
// This is how the Bantu HTTP server pushes events to connected clients.
def relaySend($toUserId, $fromUserId, $type, $data) {
    // Use sua.server.relay() to POST to the wsrelay /send endpoint
    string $payload = "{\"to\":" + str($toUserId) + ",\"from\":" + str($fromUserId) + ",\"type\":\"" + $type + "\",\"data\":" + $data + "}";
    sua.server.relay($relayUrl + "/send", $payload);
}

// ════════════════════════════════════════════════════════════════════
//  AUTH HANDLERS
// ════════════════════════════════════════════════════════════════════

def handleRegister($req, $res) {
    if (!$req.body.username || !$req.body.password) {
        $res.status(400).json({"error": "username and password are required"});
        return null;
    }
    string $username = $req.body.username;
    string $password = $req.body.password;
    string $displayName = $username;
    if ($req.body.displayName) { $displayName = $req.body.displayName; }

    list $exists = sua.sqlite.query("SELECT id FROM users WHERE username = '" + esc($username) + "';");
    if (len($exists) > 0) {
        $res.status(409).json({"error": "Username already taken"});
        return null;
    }

    string $token = newToken();
    dict $ins = sua.sqlite.exec(
        "INSERT INTO users (username, password, display_name, token) VALUES ('" +
        esc($username) + "', '" + esc($password) + "', '" + esc($displayName) + "', '" + esc($token) + "');"
    );
    number $uid = num($ins.lastInsertId);
    $res.status(201).json({
        "user": {"id": $uid, "username": $username, "displayName": $displayName},
        "token": $token,
        "message": "Account created"
    });
}

def handleLogin($req, $res) {
    if (!$req.body.username || !$req.body.password) {
        $res.status(400).json({"error": "username and password are required"});
        return null;
    }
    list $rows = sua.sqlite.query(
        "SELECT id, username, display_name, password FROM users WHERE username = '" + esc($req.body.username) + "';"
    );
    if (len($rows) == 0) {
        $res.status(401).json({"error": "Invalid credentials"});
        return null;
    }
    if ($rows[0].password != $req.body.password) {
        $res.status(401).json({"error": "Invalid credentials"});
        return null;
    }
    string $token = newToken();
    sua.sqlite.exec("UPDATE users SET token = '" + esc($token) + "' WHERE id = " + str($rows[0].id) + ";");

    $res.json({
        "user": {
            "id": num($rows[0].id),
            "username": $rows[0].username,
            "displayName": $rows[0].display_name
        },
        "token": $token,
        "message": "Login successful"
    });
}

def handleMe($req, $res) {
    dict $me = authUser($req);
    if (!$me) {
        $res.status(401).json({"error": "Not authenticated"});
        return null;
    }
    list $r = sua.sqlite.query("SELECT * FROM users WHERE id = " + str($me.id) + ";");
    $res.json({"user": publicUser($r[0])});
}

// ════════════════════════════════════════════════════════════════════
//  USERS & FOLLOWS
// ════════════════════════════════════════════════════════════════════

def handleListUsers($req, $res) {
    dict $me = authUser($req);
    if (!$me) {
        $res.status(401).json({"error": "Not authenticated"});
        return null;
    }
    list $rows = sua.sqlite.query(
        "SELECT u.id, u.username, u.display_name, u.bio, u.avatar, u.last_seen, " +
        "(SELECT COUNT(*) FROM follows WHERE follower_id = u.id) AS following_count, " +
        "(SELECT COUNT(*) FROM follows WHERE followee_id = u.id) AS followers_count, " +
        "EXISTS(SELECT 1 FROM follows WHERE follower_id = " + str($me.id) + " AND followee_id = u.id) AS is_following " +
        "FROM users u WHERE u.id != " + str($me.id) + " ORDER BY u.display_name ASC LIMIT 500;"
    );
    list $out = [];
    number $i = 0;
    each ($r in $rows) {
        $out[$i] = {
            "id": num($r.id),
            "username": $r.username,
            "displayName": $r.display_name,
            "bio": $r.bio,
            "avatar": $r.avatar,
            "online": (nowMs() - num($r.last_seen)) < 60000,
            "isFollowing": $r.is_following == 1
        };
        $i = $i + 1;
    }
    $res.json({"users": $out, "count": len($out)});
}

def handleFollow($req, $res) {
    dict $me = authUser($req);
    if (!$me) {
        $res.status(401).json({"error": "Not authenticated"});
        return null;
    }
    number $targetId = num($req.params.id);
    list $exists = sua.sqlite.query(
        "SELECT id FROM follows WHERE follower_id = " + str($me.id) + " AND followee_id = " + str($targetId) + ";"
    );
    if (len($exists) > 0) {
        $res.json({"error": "Already following"});
        return null;
    }
    sua.sqlite.exec(
        "INSERT INTO follows (follower_id, followee_id) VALUES (" + str($me.id) + ", " + str($targetId) + ");"
    );
    notify($targetId, "follow", $me.displayName + " started following you.", "/people");
    // Real-time: push follow notification via relay
    relaySend($targetId, $me.id, "notification", "{\"body\":\"" + esc($me.displayName) + " started following you.\"}");
    $res.status(201).json({"ok": true, "message": "Followed"});
}

def handleUnfollow($req, $res) {
    dict $me = authUser($req);
    if (!$me) {
        $res.status(401).json({"error": "Not authenticated"});
        return null;
    }
    number $targetId = num($req.params.id);
    sua.sqlite.exec(
        "DELETE FROM follows WHERE follower_id = " + str($me.id) + " AND followee_id = " + str($targetId) + ";"
    );
    $res.json({"ok": true, "message": "Unfollowed"});
}

// ════════════════════════════════════════════════════════════════════
//  POSTS / FEED
// ════════════════════════════════════════════════════════════════════

def handleListPosts($req, $res) {
    dict $me = authUser($req);
    if (!$me) {
        $res.status(401).json({"error": "Not authenticated"});
        return null;
    }
    list $rows = sua.sqlite.query(
        "SELECT p.*, u.username AS author_username, u.display_name AS author_name, " +
        "(SELECT COUNT(*) FROM likes WHERE post_id = p.id) AS like_count, " +
        "(SELECT COUNT(*) FROM comments WHERE post_id = p.id) AS comment_count, " +
        "EXISTS(SELECT 1 FROM likes WHERE post_id = p.id AND user_id = " + str($me.id) + ") AS liked " +
        "FROM posts p JOIN users u ON u.id = p.user_id " +
        "WHERE p.user_id IN (SELECT followee_id FROM follows WHERE follower_id = " + str($me.id) + ") OR p.user_id = " + str($me.id) + " " +
        "ORDER BY p.created_at DESC LIMIT 100;"
    );
    list $out = [];
    number $i = 0;
    each ($r in $rows) {
        $out[$i] = postFromRow($r, num($r.like_count), num($r.comment_count));
        $out[$i].liked = ($r.liked == 1);
        $i = $i + 1;
    }
    $res.json({"posts": $out, "count": len($out)});
}

def handleCreatePost($req, $res) {
    dict $me = authUser($req);
    if (!$me) {
        $res.status(401).json({"error": "Not authenticated"});
        return null;
    }
    if (!$req.body.body) {
        $res.status(400).json({"error": "body is required"});
        return null;
    }
    string $image = "";
    if ($req.body.image) { $image = esc($req.body.image); }
    dict $ins = sua.sqlite.exec(
        "INSERT INTO posts (user_id, body, image) VALUES (" + str($me.id) + ", '" + esc($req.body.body) + "', '" + $image + "');"
    );
    $res.status(201).json({
        "post": {
            "id": num($ins.lastInsertId),
            "userId": $me.id,
            "authorName": $me.displayName,
            "authorUsername": $me.username,
            "body": $req.body.body,
            "image": $image,
            "createdAt": "",
            "likes": 0,
            "comments": 0,
            "liked": false
        },
        "message": "Posted"
    });
}

def handleLikePost($req, $res) {
    dict $me = authUser($req);
    if (!$me) {
        $res.status(401).json({"error": "Not authenticated"});
        return null;
    }
    number $pid = num($req.params.id);
    list $exists = sua.sqlite.query(
        "SELECT id FROM likes WHERE post_id = " + str($pid) + " AND user_id = " + str($me.id) + ";"
    );
    if (len($exists) > 0) {
        sua.sqlite.exec("DELETE FROM likes WHERE post_id = " + str($pid) + " AND user_id = " + str($me.id) + ";");
        list $cnt = sua.sqlite.query("SELECT COUNT(*) AS n FROM likes WHERE post_id = " + str($pid) + ";");
        $res.json({"liked": false, "likes": num($cnt[0].n)});
        return null;
    }
    sua.sqlite.exec(
        "INSERT INTO likes (post_id, user_id) VALUES (" + str($pid) + ", " + str($me.id) + ");"
    );
    list $owner = sua.sqlite.query("SELECT user_id FROM posts WHERE id = " + str($pid) + ";");
    if (len($owner) > 0 && num($owner[0].user_id) != $me.id) {
        notify(num($owner[0].user_id), "like", $me.displayName + " liked your post.", "/post/" + str($pid));
    }
    list $cnt = sua.sqlite.query("SELECT COUNT(*) AS n FROM likes WHERE post_id = " + str($pid) + ";");
    $res.json({"liked": true, "likes": num($cnt[0].n)});
}

def handleListComments($req, $res) {
    dict $me = authUser($req);
    if (!$me) {
        $res.status(401).json({"error": "Not authenticated"});
        return null;
    }
    number $pid = num($req.params.id);
    list $rows = sua.sqlite.query(
        "SELECT c.id, c.body, c.created_at, u.id AS user_id, u.username, u.display_name " +
        "FROM comments c JOIN users u ON u.id = c.user_id " +
        "WHERE c.post_id = " + str($pid) + " ORDER BY c.created_at ASC;"
    );
    list $out = [];
    number $i = 0;
    each ($r in $rows) {
        $out[$i] = {
            "id": num($r.id),
            "body": $r.body,
            "createdAt": $r.created_at,
            "user": {
                "id": num($r.user_id),
                "username": $r.username,
                "displayName": $r.display_name
            }
        };
        $i = $i + 1;
    }
    $res.json({"comments": $out, "count": len($out)});
}

def handleCreateComment($req, $res) {
    dict $me = authUser($req);
    if (!$me) {
        $res.status(401).json({"error": "Not authenticated"});
        return null;
    }
    if (!$req.body.body) {
        $res.status(400).json({"error": "body is required"});
        return null;
    }
    number $pid = num($req.params.id);
    dict $ins = sua.sqlite.exec(
        "INSERT INTO comments (post_id, user_id, body) VALUES (" + str($pid) + ", " + str($me.id) + ", '" + esc($req.body.body) + "');"
    );
    list $owner = sua.sqlite.query("SELECT user_id FROM posts WHERE id = " + str($pid) + ";");
    if (len($owner) > 0 && num($owner[0].user_id) != $me.id) {
        notify(num($owner[0].user_id), "comment", $me.displayName + " commented on your post.", "/post/" + str($pid));
    }
    $res.status(201).json({
        "comment": {
            "id": num($ins.lastInsertId),
            "body": $req.body.body,
            "createdAt": "",
            "user": {"id": $me.id, "username": $me.username, "displayName": $me.displayName}
        },
        "message": "Comment added"
    });
}

// ════════════════════════════════════════════════════════════════════
//  REAL-TIME CHAT (WebSocket)
//  Messages are stored in SQLite for history.
//  Delivery is instant via WebSocket relay — ZERO polling.
//  Flow:
//    A: POST /api/messages/:toId  {body}
//       → inserts into SQLite
//       → forwards to wsrelay → B's WebSocket
//    B: receives msg via WS event "message" instantly
//    B: opens chat → GET /api/messages/:peerId (history, one-time)
// ════════════════════════════════════════════════════════════════════

def handleListMessages($req, $res) {
    dict $me = authUser($req);
    if (!$me) {
        $res.status(401).json({"error": "Not authenticated"});
        return null;
    }
    number $peerId = num($req.params.id);
    number $since = 0;
    if ($req.query.since) { $since = num($req.query.since); }

    list $rows = sua.sqlite.query(
        "SELECT id, from_id, to_id, body, created_at, delivered FROM messages " +
        "WHERE ((from_id = " + str($me.id) + " AND to_id = " + str($peerId) + ") " +
        "OR (from_id = " + str($peerId) + " AND to_id = " + str($me.id) + ")) " +
        "AND id > " + str($since) + " ORDER BY id ASC LIMIT 200;"
    );

    // Mark inbound messages as delivered
    sua.sqlite.exec(
        "UPDATE messages SET delivered = 1 WHERE to_id = " + str($me.id) + " AND delivered = 0;"
    );

    list $out = [];
    number $i = 0;
    each ($r in $rows) {
        $out[$i] = {
            "id": num($r.id),
            "fromId": num($r.from_id),
            "toId": num($r.to_id),
            "body": $r.body,
            "createdAt": $r.created_at,
            "delivered": $r.delivered == 1
        };
        $i = $i + 1;
    }
    $res.json({"messages": $out, "count": len($out), "serverTime": nowMs()});
}

def handleSendMessage($req, $res) {
    dict $me = authUser($req);
    if (!$me) {
        $res.status(401).json({"error": "Not authenticated"});
        return null;
    }
    number $peerId = num($req.params.id);
    if (!$req.body.body) {
        $res.status(400).json({"error": "body is required"});
        return null;
    }
    dict $ins = sua.sqlite.exec(
        "INSERT INTO messages (from_id, to_id, body) VALUES (" + str($me.id) + ", " + str($peerId) + ", '" + esc($req.body.body) + "');"
    );
    notify($peerId, "message", $me.displayName + " sent you a message.", "/chat/" + str($me.id));

    // Real-time: push message to recipient via WebSocket relay
    string $msgData = "{\"body\":\"" + esc($req.body.body) + "\",\"id\":" + str(num($ins.lastInsertId)) + "}";
    relaySend($peerId, $me.id, "message", $msgData);

    $res.status(201).json({
        "message": {
            "id": num($ins.lastInsertId),
            "fromId": $me.id,
            "toId": $peerId,
            "body": $req.body.body,
            "createdAt": "",
            "delivered": false
        }
    });
}

def handleConversations($req, $res) {
    dict $me = authUser($req);
    if (!$me) {
        $res.status(401).json({"error": "Not authenticated"});
        return null;
    }
    list $rows = sua.sqlite.query(
        "SELECT m.id, m.from_id, m.to_id, m.body, m.created_at, m.delivered, " +
        "  CASE WHEN m.from_id = " + str($me.id) + " THEN m.to_id ELSE m.from_id END AS peer_id, " +
        "  u.username AS peer_username, u.display_name AS peer_display_name, u.last_seen AS peer_last_seen " +
        "FROM messages m " +
        "JOIN users u ON u.id = (CASE WHEN m.from_id = " + str($me.id) + " THEN m.to_id ELSE m.from_id END) " +
        "WHERE m.id IN (" +
        "  SELECT MAX(id) FROM (" +
        "    SELECT id, from_id AS peer_id FROM messages WHERE to_id = " + str($me.id) +
        "    UNION ALL" +
        "    SELECT id, to_id AS peer_id FROM messages WHERE from_id = " + str($me.id) +
        "  ) GROUP BY peer_id" +
        ") ORDER BY m.id DESC;"
    );
    list $out = [];
    number $i = 0;
    each ($r in $rows) {
        $out[$i] = {
            "peer": {
                "id": num($r.peer_id),
                "username": $r.peer_username,
                "displayName": $r.peer_display_name,
                "online": (nowMs() - num($r.peer_last_seen)) < 60000
            },
            "lastMessage": {
                "id": num($r.id),
                "fromId": num($r.from_id),
                "toId": num($r.to_id),
                "body": $r.body,
                "createdAt": $r.created_at,
                "delivered": $r.delivered == 1
            }
        };
        $i = $i + 1;
    }
    $res.json({"conversations": $out, "count": len($out)});
}

def handleUnreadCount($req, $res) {
    dict $me = authUser($req);
    if (!$me) {
        $res.status(401).json({"error": "Not authenticated"});
        return null;
    }
    list $rows = sua.sqlite.query(
        "SELECT COUNT(*) AS n FROM messages WHERE to_id = " + str($me.id) + " AND delivered = 0;"
    );
    number $messages = num($rows[0].n);
    list $nrows = sua.sqlite.query(
        "SELECT COUNT(*) AS n FROM notifications WHERE user_id = " + str($me.id) + " AND is_read = 0;"
    );
    number $notifs = num($nrows[0].n);
    $res.json({"unreadMessages": $messages, "unreadNotifications": $notifs});
}

// ════════════════════════════════════════════════════════════════════
//  PRESENCE — tracked by WebSocket connections in wsrelay.
//  Online = has an active WebSocket connection.
//  The /api/presence endpoint is kept for initial load / fallback.
//  Real-time presence updates come via WS "presence" events.
// ════════════════════════════════════════════════════════════════════

def handlePresenceHeartbeat($req, $res) {
    dict $me = authUser($req);
    if (!$me) {
        $res.status(401).json({"error": "Not authenticated"});
        return null;
    }
    sua.sqlite.exec("UPDATE users SET last_seen = " + str(nowMs()) + " WHERE id = " + str($me.id) + ";");
    $res.json({"ok": true, "online": true, "timestamp": nowMs()});
}

def handlePresenceList($req, $res) {
    dict $me = authUser($req);
    if (!$me) {
        $res.status(401).json({"error": "Not authenticated"});
        return null;
    }
    list $rows = sua.sqlite.query(
        "SELECT id, username, display_name FROM users WHERE last_seen > " + str(nowMs() - 60000) +
        " AND id != " + str($me.id) + " ORDER BY display_name ASC LIMIT 200;"
    );
    list $out = [];
    number $i = 0;
    each ($r in $rows) {
        $out[$i] = {
            "id": num($r.id),
            "username": $r.username,
            "displayName": $r.display_name,
            "online": true
        };
        $i = $i + 1;
    }
    $res.json({"online": $out, "count": len($out)});
}

// ════════════════════════════════════════════════════════════════════
//  NOTIFICATIONS
// ════════════════════════════════════════════════════════════════════

def handleListNotifications($req, $res) {
    dict $me = authUser($req);
    if (!$me) {
        $res.status(401).json({"error": "Not authenticated"});
        return null;
    }
    list $rows = sua.sqlite.query(
        "SELECT id, type, body, link, is_read, created_at FROM notifications WHERE user_id = " + str($me.id) +
        " ORDER BY id DESC LIMIT 50;"
    );
    list $out = [];
    number $i = 0;
    each ($r in $rows) {
        $out[$i] = {
            "id": num($r.id),
            "type": $r.type,
            "body": $r.body,
            "link": $r.link,
            "isRead": $r.is_read == 1,
            "createdAt": $r.created_at
        };
        $i = $i + 1;
    }
    // Mark as read
    sua.sqlite.exec("UPDATE notifications SET is_read = 1 WHERE user_id = " + str($me.id) + " AND is_read = 0;");
    $res.json({"notifications": $out, "count": len($out)});
}

// ════════════════════════════════════════════════════════════════════
//  HEALTH & OPTIONS
// ════════════════════════════════════════════════════════════════════

def handleHealth($req, $res) {
    $res.json({
        "status": "ok",
        "language": "Bantu",
        "framework": "Sua",
        "database": "SQLite",
        "app": "ChatBantu",
        "version": "2.0.0",
        "realtime": "WebSocket",
        "turn": "embedded (port 3478)",
        "serverTime": nowMs()
    });
}

def handleOptions($req, $res) {
    $res.set("Access-Control-Allow-Origin", "*");
    $res.set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    $res.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
    $res.status(200).send("");
}

// ════════════════════════════════════════════════════════════════════
//  ROUTE REGISTRATION
// ════════════════════════════════════════════════════════════════════

sua.server.get("/api/health",                         handleHealth);

// Auth
sua.server.post("/api/auth/register",                 handleRegister);
sua.server.post("/api/auth/login",                    handleLogin);
sua.server.get("/api/auth/me",                        handleMe);

// Users & follows
sua.server.get("/api/users",                          handleListUsers);
sua.server.post("/api/users/:id/follow",              handleFollow);
sua.server.delete("/api/users/:id/follow",            handleUnfollow);

// Posts / feed
sua.server.get("/api/posts",                          handleListPosts);
sua.server.post("/api/posts",                         handleCreatePost);
sua.server.post("/api/posts/:id/like",                handleLikePost);
sua.server.get("/api/posts/:id/comments",             handleListComments);
sua.server.post("/api/posts/:id/comments",            handleCreateComment);

// Real-time chat (WebSocket + SQLite for history)
sua.server.get("/api/messages/:id",                   handleListMessages);
sua.server.post("/api/messages/:id",                  handleSendMessage);
sua.server.get("/api/conversations",                  handleConversations);
sua.server.get("/api/unread",                         handleUnreadCount);

// Presence (fallback — real-time via WS)
sua.server.post("/api/presence",                      handlePresenceHeartbeat);
sua.server.get("/api/presence",                       handlePresenceList);

// Notifications
sua.server.get("/api/notifications",                  handleListNotifications);

// CORS preflight
sua.server.options("/*",                              handleOptions);

// Static frontend
sua.server.static("./public");

// ════════════════════════════════════════════════════════════════════
//  START SERVER
// ════════════════════════════════════════════════════════════════════
print "";
print "═══════════════════════════════════════════";
print "  ChatBantu v2 API ready";
print "  HTTP:     http://0.0.0.0:" + $envPort;
print "  WS Relay: ws://0.0.0.0:" + $relayPort;
print "  TURN:     embedded (port 3478)";
print "  Database: " + $dbPath + " (SQLite)";
print "  Real-time: WebSocket (zero polling)";
print "  Signaling: WebSocket relay";
print "═══════════════════════════════════════════";
print "";
print "  To start the WebSocket relay:";
print "    ./wsrelay " + $relayPort + " " + $dbPath;
print "";

sua.server.listen(num($envPort));