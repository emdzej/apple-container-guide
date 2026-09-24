const http = require("http");
const os = require("os");
const fs = require("fs");

const PORT = process.env.PORT || 8000;

http
  .createServer((req, res) => {
    if (req.url === "/healthz") {
      res.writeHead(200).end("ok");
      return;
    }
    const mounted = fs.existsSync("/app/message.txt")
      ? fs.readFileSync("/app/message.txt", "utf8").trim()
      : "(no bind mount)";
    res.writeHead(200, { "content-type": "text/plain" }).end(
      [
        `hostname:  ${os.hostname()}`,
        `platform:  ${process.platform}/${process.arch}`,
        `cpus:      ${os.cpus().length}`,
        `memory:    ${(os.totalmem() / 1024 ** 3).toFixed(2)} GiB`,
        `mounted:   ${mounted}`,
      ].join("\n") + "\n",
    );
  })
  .listen(PORT, "0.0.0.0", () => console.log(`listening on 0.0.0.0:${PORT}`));
