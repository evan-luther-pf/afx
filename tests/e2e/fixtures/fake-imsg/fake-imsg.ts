import { execFileSync } from "node:child_process";
import { existsSync, unlinkSync } from "node:fs";

export function buildAttributedBodyBytes(
  text: string,
  lengthForm: "1byte" | "u16" | "u32" = "1byte",
): Buffer {
  const textBytes = Buffer.from(text, "utf8");
  const header = Buffer.from("040b737472654e53537472696e67019484012b", "hex");
  const trailer = Buffer.from("86", "hex");

  let lenBuf: Buffer;
  if (lengthForm === "1byte") {
    lenBuf = Buffer.from([textBytes.length]);
  } else if (lengthForm === "u16") {
    lenBuf = Buffer.alloc(3);
    lenBuf[0] = 0x81;
    lenBuf.writeUInt16LE(textBytes.length, 1);
  } else {
    lenBuf = Buffer.alloc(5);
    lenBuf[0] = 0x82;
    lenBuf.writeUInt32LE(textBytes.length, 1);
  }

  return Buffer.concat([header, lenBuf, textBytes, trailer]);
}

export class FakeImsgDatabase {
  dbPath: string;

  constructor(dbPath: string) {
    this.dbPath = dbPath;
  }

  static create(dbPath: string): FakeImsgDatabase {
    if (existsSync(dbPath)) {
      try {
        unlinkSync(dbPath);
      } catch {}
    }

    const schema = `
      PRAGMA journal_mode = WAL;
      PRAGMA busy_timeout = 5000;
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        guid TEXT,
        text TEXT,
        attributedBody BLOB,
        handle_id INTEGER,
        is_from_me INTEGER DEFAULT 0,
        date INTEGER DEFAULT 0
      );
      CREATE TABLE handle (
        ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT UNIQUE
      );
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        guid TEXT UNIQUE
      );
      CREATE TABLE chat_message_join (
        chat_id INTEGER,
        message_id INTEGER,
        PRIMARY KEY (chat_id, message_id)
      );
      CREATE TABLE chat_handle_join (
        chat_id INTEGER,
        handle_id INTEGER,
        PRIMARY KEY (chat_id, handle_id)
      );
    `;

    execFileSync("sqlite3", [dbPath, schema], { encoding: "utf8" });
    return new FakeImsgDatabase(dbPath);
  }

  appendMessage(opts: {
    handle: string;
    chatGuid: string;
    text?: string | null;
    attributedBody?: Buffer | Uint8Array | null;
    isFromMe?: number;
  }): number {
    const isFromMe = opts.isFromMe ?? 0;
    const guid = `msg_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
    const escapedHandle = opts.handle.replace(/'/g, "''");
    const escapedChat = opts.chatGuid.replace(/'/g, "''");

    const textExpr = opts.text != null ? `'${opts.text.replace(/'/g, "''")}'` : "NULL";
    const attrExpr = opts.attributedBody != null ? `X'${Buffer.from(opts.attributedBody).toString("hex")}'` : "NULL";

    const atomicSql = `
      PRAGMA busy_timeout = 5000;
      BEGIN IMMEDIATE;
      INSERT OR IGNORE INTO handle (id) VALUES ('${escapedHandle}');
      INSERT OR IGNORE INTO chat (guid) VALUES ('${escapedChat}');
      INSERT OR IGNORE INTO chat_handle_join (chat_id, handle_id)
        SELECT c.ROWID, h.ROWID FROM chat c, handle h WHERE c.guid = '${escapedChat}' AND h.id = '${escapedHandle}';
      INSERT INTO message (guid, text, attributedBody, handle_id, is_from_me)
        SELECT '${guid}', ${textExpr}, ${attrExpr}, h.ROWID, ${isFromMe} FROM handle h WHERE h.id = '${escapedHandle}';
      INSERT INTO chat_message_join (chat_id, message_id)
        SELECT c.ROWID, last_insert_rowid() FROM chat c WHERE c.guid = '${escapedChat}';
      SELECT last_insert_rowid();
      COMMIT;
    `;

    const rowIdStr = execFileSync("sqlite3", [this.dbPath, atomicSql], {
      encoding: "utf8",
    }).trim();
    return parseInt(rowIdStr, 10);
  }
}
