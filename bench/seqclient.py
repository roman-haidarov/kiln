import socket, sys, time
port=int(sys.argv[1]); n=int(sys.argv[2])
for _ in range(100):
    try:
        s=socket.create_connection(("127.0.0.1",port)); break
    except OSError: time.sleep(0.1)
req=b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
buf=b""; done=0
for i in range(n):
    s.sendall(req)
    while True:
        h=buf.find(b"\r\n\r\n")
        if h>=0:
            cl=int(buf[:h].lower().split(b"content-length: ")[1].split(b"\r\n")[0])
            if len(buf)>=h+4+cl:
                buf=buf[h+4+cl:]; done+=1; break
        buf+=s.recv(65536)
s.close(); print(done)
