# Container Ports Overview

## Port Reference

| Port            | Protocol | Container   | Purpose                          |
| --------------- | -------- | ----------- | -------------------------------- |
| **20**          | TCP      | transferium | FTP data channel (active mode)   |
| **21**          | TCP      | transferium | FTP control channel              |
| **22**          | TCP      | transferium | SFTP/SSH file transfer           |
| **69**          | UDP      | transferium | TFTP (Trivial FTP)               |
| **514**         | UDP      | syslog-ng   | Syslog (standard UDP)            |
| **601**         | TCP      | syslog-ng   | Syslog over TCP (RFC 3195)       |
| **5432**        | TCP      | db          | PostgreSQL database              |
| **6379**        | TCP      | redis       | Redis (internal only)            |
| **6614**        | TCP      | syslog-ng   | Syslog TLS (secure syslog)       |
| **8000**        | TCP      | api         | REST API (uvicorn)               |
| **80**          | TCP      | frontend    | Web UI (nginx)                   |
| **8080**        | TCP      | swagger     | Swagger UI (internal only)       |
| **8765**        | TCP      | agent       | Agent WebSocket/API              |
| **9418**        | TCP      | gitd        | Git protocol (native git://)     |
| **9419**        | TCP      | gitdctrl    | Git daemon controller/management |
| **31000-31015** | TCP      | transferium | FTP passive mode data ports      |

## Containers

| Container   | Image                     | Exposed Ports                      | Purpose                          |
| ----------- | ------------------------- | ---------------------------------- | -------------------------------- |
| syslog-ng   | netpicker/syslog-ng       | 514/udp, 601/tcp, 6614/tcp         | Syslog server for log collection |
| frontend    | netpicker/tester-frontend | 8008/tcp                           | Web UI                           |
| celery      | netpicker/api             | (none)                             | Background task worker           |
| kibbitzer   | netpicker/kibbitzer       | (none)                             | Internal service                 |
| agent       | netpicker/agent           | 8765/tcp                           | Agent communication              |
| swagger     | swaggerapi/swagger-ui     | (none)                             | API documentation UI             |
| api         | netpicker/api             | 8000/tcp                           | REST API server                  |
| db          | netpicker/db              | 5432/tcp                           | PostgreSQL database              |
| gitdctrl    | netpicker/gitdctrl        | 9419/tcp                           | Git daemon controller            |
| transferium | netpicker/transferium     | 20-22/tcp, 69/udp, 31000-31015/tcp | FTP/SFTP/TFTP file transfer      |
| gitd        | netpicker/gitd            | 9418/tcp                           | Git daemon (git protocol)        |
| redis       | redis:7-alpine            | (none)                             | Cache/message broker             |

## Protocol Groups

### File Transfer (transferium)

- **FTP**: 20 (data), 21 (control), 31000-31015 (passive)
- **SFTP**: 22
- **TFTP**: 69

### Logging (syslog-ng)

- **UDP**: 514 (standard syslog)
- **TCP**: 601 (reliable syslog)
- **TLS**: 6614 (secure syslog)

### Git Services

- **gitd**: 9418 (native git protocol)
- **gitdctrl**: 9419 (management)

### Web/API

- **frontend**: 80 (Web UI)
- **api**: 8000 (REST API)
- **agent**: 8765 (WebSocket/API)

### Data

- **db**: 5432 (PostgreSQL)
- **redis**: 6379 (internal)
