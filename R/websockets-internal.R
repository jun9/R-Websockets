# Notes:
# - no extensions
# - subprotocol is ignored for now
# - fragmentation is not supported yet

.onLoad = function(libname,pkgname)
{
  options(websockets_max_buffer_size=16777216)
}
.onUnload = function(libpath)
{
  options(websockets_max_buffer_size=NULL)
}

# numToBits can convert large integers to bits.
# It uses the same bit ordering as intToBits.
.numToBits = function(x, fixedLength=NULL)
{
  j = 1;
  r = raw(1);
  if(round(x)!=x) {
    x = round(x)
    warning("Rounding x to whole number")
  }
  if(!is.null(fixedLength)) r = raw(fixedLength)
  one = intToBits(1L)[1]
  while(x>0) {
    if((x %% 2)==1){
      r[j] = one
      x = x - 1
    } else r[j] = raw(1)
    x = x / 2
    j = j + 1
  }
  if(!is.null(fixedLength)) r = r[1:fixedLength]
  r
}

.parse_header = function(msg)
{
# Check to make sure this is a valid GET or POST request. Error out if msg is
# not of the right type, or return null right away if it does not start with
# GET or POS.
  cli_header = list()
  if(!(is.character(msg) || is.raw(msg))) stop("Must be raw or character")
  n = ifelse(is.raw(msg),length(msg),nchar(msg))
  if(n<3) return(c())
  if(is.raw(msg)) if(msg[1]==raw(1)) return(c())
  GET = tryCatch({ifelse(is.raw(msg),rawToChar(msg[1:3]), substr(msg,1,3))},
                 error=function(e) c())
  if(!(GET %in% c("GET","POS"))) return(c())
  rtype = "GET"
  if(GET == "POS") rtype = "POST"
# We are dealing with a GET or POST request, OK to continue.
  if(is.raw(msg)) {
    cli_header$raw = msg
    msg = rawToChar(msg[msg!=0])
  }
  if(n<1) return(cli_header)
  x = gsub("\r","",msg)
  x = strsplit(x,"\n")
  if(length(x)<1) return(cli_header)
  x = x[[1]]
  l = grep(paste("^",rtype,sep=""),x,ignore.case=TRUE)
  cli_header$GET = ifelse(length(l)>0,x[l[1]],"")
  cli_header$TYPE = rtype
  GET = strsplit(cli_header$GET," ")[[1]]
  if(length(GET>2)) {
    cli_header$PROT = tail(GET,1)
    cli_header$RESOURCE = GET[2]
  }
  if(length(l)>0) x = x[-l]
  for(j in 1:length(x)) {
    n = gregexpr(":",text=x[j])[[1]]
    if(!is.na(n) && n[1]>1) {
      key = substr(x[j],1,n-1)
      value = substr(x[j],n+1,nchar(x[j]))
      value = gsub("^ *", "", value)
      cli_header[key] = value
    }
    else break;
  }
  cli_header
}

# Version 00 handshake, which is amazingly lame
.v00_resp_101 = function(cli_header, cli_sock)
{
  er=charToRaw("HTTP/1.1 400 BAD REQUEST\r\n\r\n")
  prot = cli_header["Sec-WebSocket-Protocol"][[1]]
  origin = cli_header["Origin"]
  location = paste("ws://",cli_header["Host"],"/",sep="")
  key1 = cli_header["Sec-WebSocket-Key1"][[1]]
  key2 = cli_header["Sec-WebSocket-Key2"][[1]]
  if(is.null(key1) || is.null(key2)) return(er)
  if(!is.character(key1) || !is.character(key2)) return(er)
  num1 = tryCatch(as.numeric(rawToChar(charToRaw(key1)[gregexpr("[0-9]",text=key1)[[1]]])),
                  error=function(e) return(er))
  num2 = tryCatch(as.numeric(rawToChar(charToRaw(key2)[gregexpr("[0-9]",text=key2)[[1]]])),
                  error=function(e) return(er))
  s1 = length(charToRaw(key1)[gregexpr(" ",text=key1)[[1]]])
  s2 = length(charToRaw(key2)[gregexpr(" ",text=key2)[[1]]])
  v1 = num1/s1
  v2 = num2/s2
  n = length(cli_header$raw)
#  pos = grepRaw(charToRaw("\r\n\r\n"),cli_header$raw,all=TRUE)
#  if(length(pos)<1) return(charToRaw("HTTP/1.1 400 BAD REQUEST\r\n\r\n"))
#  if(length(pos)>1) pos=pos[length(pos)]
#  if(length(cli_header$raw)< pos+11) return(charToRaw("HTTP/1.1 400 BAD REQUEST\r\n\r\n"))
#  key3 = cli_header$raw[(pos+4):(pos+11)]
  check = .SOCK_POLL(cli_sock)
  if(check <1)return(er)
  key3 = .SOCK_RECV(cli_sock)
  if(length(key3)<8) return(er)
  key3 = key3[1:8]
  r1 = packBits(.numToBits(v1,32))[4:1]
  r2 = packBits(.numToBits(v2,32))[4:1]
  val = c(r1,r2,key3)
  hash = digest(val,algo="md5",serialize=FALSE,raw=TRUE)
  resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: WebSocket\r\nConnection: Upgrade\r\n"
  resp = paste(resp,"Sec-WebSocket-Origin: ",origin,"\r\n",sep="")
  resp = paste(resp,"Sec-WebSocket-Location: ",location,"\r\n",sep="")
  resp = paste(resp,"Sec-WebSocket-Protocol: ",prot,"\r\n\r\n",sep="")
  c(charToRaw(resp),hash)
}

# Version 04 to at least 15 handshake
.v04_resp_101 = function(cli_header)
{
  GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  key = paste(cli_header["Sec-WebSocket-Key"],GUID,sep="") 
  skey = base64encode(digest(charToRaw(key),algo='sha1',serialize=FALSE,raw=TRUE))
  prot = cli_header["Sec-WebSocket-Protocol"][[1]]
  resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
  resp = paste(resp,"Sec-WebSocket-Protocol: ",prot,"\r\n",sep="")
  paste(resp,"Sec-WebSocket-Accept: ",skey,"\r\n\r\n",sep="")
}

# Low-level frame header generator, extensions not supported
# Version 01 to at least 15 data framing
# The bit ordering is a bit hard to follow, sorry.
.frame = function(len, FIN=TRUE, opcode=1L, mask=FALSE)
{
  if(is.character(opcode)) opcode = strtoi(opcode, 16L)
  head = rawToBits(raw(1))    # First byte of header
  if(FIN) head[8] = as.raw(1)
  head[1:4] = rawToBits(as.raw(opcode))[1:4]
  head2 = rawToBits(raw(1))    # 2nd byte of header
  rest  = raw(0)              # Optional 3rd -- 6th bytes
  if(mask) head2[8] = as.raw(1)
  if(len < 126) {
    head2[1:7] = rawToBits(as.raw(len))[1:7]
  }
  else if(len > 65535) {
# 8-byte data length, but we only use 4 bytes
    head2[1:7] = rawToBits(as.raw(127))[1:7]
    rest = raw(8)
    rest[8:5] = packBits(intToBits(len),type="raw")
  }
  else {
# 2-byte data length
    head2[1:7] = rawToBits(as.raw(126))[1:7]
    rest = packBits(intToBits(len),type="raw")[2:1]
  }
  c(packBits(head), packBits(head2), rest)
}

# Returns raw message (could be NULL) or FALSE if the client wants
# to close the connection.
.v00_unframe = function(data)
{
  ff = as.raw(255)
  if(data[1]==ff) return(FALSE)
  eof = which(data==ff)
  if(length(eof)<1) return(FALSE)
  data = data[1:eof[1]]
  if(data[length(data)] != ff) warning("End of message missing")
  return(data[2:(length(data)-1)])
}

# Parse a frame header, data must be a raw vector for now, but external
# pointer will be supported soon (external pointer messages can be unmasked
# in place).
#
# The bit ordering is a bit hard to follow, sorry.
# This version of unframe returns a list with two elements:
# header: the frame header
# data:   the unmasked frame data payload or NULL
#
# Fragmentation, binary/text, opcodes, etc. must be handled by the high-level
# receive function. NOTE!
.unframe = function(data)
{
  frame=list()
  frame$FIN = 0L
  frame$mask = FALSE
  frame$offset = 3L  # default 2-byte header
  if(is.raw(data)) {
    head = rawToBits(data[1])
    if(head[1]) frame$FIN = 1L
    x = rawToBits(raw(1))
    x[1:4] = head[8:5]
    frame$opcode = as.integer(packBits(x))
    head2 = rawToBits(data[2])
    if(head2[8]) frame$mask = TRUE
    x = rawToBits(raw(1))
    x[1:7] = head2[1:7]
    frame$len = as.integer(packBits(x))
    if(frame$len == 126) {
# 2-byte data length
      x = raw(4)
      x[1:2] = data[4:3]
      frame$len = packBits(rawToBits(x),type="integer")
      frame$offset = frame$offset + 2L
    }
    else if(frame$len == 127) {
# 8-byte data length
      x = raw(4)
      x = data[10:7]
      frame$len = packBits(rawToBits(x),type="integer")
      frame$offset = frame$offset + 8L
      x = raw(4)
      x = data[6:3]
      x = packBits(rawToBits(x),type="integer")
      if(x!=0) warning("Message length exceeds limit.")
    }
    if(frame$mask) {
      frame$key = data[frame$offset:(frame$offset+3)]
      frame$offset = frame$offset + 4L
    }
  }
  else{
    stop("Only raw message types presently supported.")
  }
  if(length(data) < frame$offset || (is.null(frame$key) && frame$mask)) 
    return(list(header=frame,data=c()))
  if(frame$mask)
    return(list(header=frame,
                data=.MASK(data[frame$offset:(frame$len + frame$offset - 1)],
                           frame$key)))
  return(list(header=frame,data=data[frame$offset:(frame$len + frame$offset - 1)]))
}

`.add_client` <- function(socket, server)
{
  cs <- .SOCK_ACCEPT(socket)
  client_sockets = server$client_sockets
#  client_sockets[[length(client_sockets)+1]] =
  client_sockets[[as.character(cs)]] = 
    list(socket=cs, wsinfo=NULL, server=server, new=TRUE)
  assign('client_sockets',client_sockets, envir=server)
  invisible()
}

`.remove_client` <- function(socket)
{
  server <- socket$server
  cs <- socket$server$client_sockets
#  cs <- cs[!(unlist(lapply(cs,function(x) x$socket)) == socket$socket)]
  cs[[as.character(socket$socket)]] = c()
  j = .SOCK_CLOSE(socket$socket)
  assign('client_sockets',cs, envir=server)
# Trigger client closed callback
  if(exists("closed", envir=server))
    server$closed(socket)
  j
}

.http_400 = function(socket)
{
  .SOCK_SEND(socket,charToRaw("HTTP/1.1 400 BAD REQUEST\r\n\r\n<!DOCTYPE html><html><body><h1>400 Bad request.</h1></body></html>"))
  TRUE
}

# Generic, very basic 200 response.
# other example maybe in response to /favicon.ico for example:
# .http_200(socket, "image/x-icon",.html5ico)
# Or JSON transactions:
# .http_200(socket, "application/json", <content>)
# etc.
.http_200 = function(socket, content_type="text/html; charset=UTF-8",
                    content="<html><body><h1>R Websocket Server</h1></body></html>")
{
  n = ifelse(is.character(content),nchar(content), length(content))
  h="HTTP/1.1 200 OK\r\nServer: R/Websocket\r\n"
  h=paste(h,"Content-Type: ",content_type, "\r\n",sep="")
  h=paste(h,"Date: ",date(),"\r\n",sep="")
  h=paste(h,"Content-Length: ",n,"\r\n\r\n",sep="")
  .SOCK_SEND(socket,charToRaw(h))
  if(is.character(content))
    .SOCK_SEND(socket,charToRaw(content))
  else
    .SOCK_SEND(socket,content)
  .SOCK_CLOSE(socket)
  TRUE
}

# A basic and generic http response function
http_response = function(socket, status=200,
                         content_type="text/html; charset=UTF-8", content="")
{
  n = ifelse(is.character(content),nchar(content), length(content))
  h=paste("HTTP/1.1",status,"OK\r\nServer: R/Websocket\r\n")
  h=paste(h,"Content-Type: ",content_type, "\r\n",sep="")
  h=paste(h,"Date: ",date(),"\r\n",sep="")
  h=paste(h,"Content-Length: ",n,"\r\n\r\n",sep="")
  .SOCK_SEND(socket,charToRaw(h))
  if(is.character(content))
    .SOCK_SEND(socket,charToRaw(content))
  else
    .SOCK_SEND(socket,content)
  .SOCK_CLOSE(socket)
  TRUE
}

# Parse http get/post variables, returning a list
http_vars = function(socket, header)
{
  res = strsplit(header$RESOURCE,split="\\?")[[1]]
# XXX XXX XXX WRONG! FIX THIS
  if(header$TYPE=="POST")
    GET = rawToChar(websockets:::.SOCK_RECV_HTTP_HEAD(socket))
  else GET = res[2]
  if(!is.na(GET) && nchar(GET)>1) {
    GET = lapply(strsplit(GET,"&")[[1]],function(x) strsplit(x,"=")[[1]])
    gnams = lapply(GET,function(x) x[[1]])
    GET = lapply(GET,function(x) if(length(x)>1){.urldecode(x[[2]])} else{c()})
    names(GET) = gnams
  } else GET = c()
  GET
}

.urldecode = function(x)
{
  j = 1
  while(j<nchar(x)) {
    if(substr(x,j,j)=="%") {
      s = substr(x,j,j+2)
      x = sub(s,intToUtf8(sub("\\%","0x",s)),x)
    }
    j = j + 1
  }
  gsub("\\+"," ",x)
}

.html5ico = base64decode("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8f8pZfH/////////////////1+L8/yll8f8pZfH/J1Pn/yZN5P8mTeSPAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJk3kvyZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yll8f8pZfH/KWXx/yll8f/k7P3/////////////////KWXx/yll8f8nU+f/Jk3k/yZN5L8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAmTeS/Jk3k/yZN5P8mTeT/Jk3k/7rE6f+6xOn/usTp/7rE6f+6xOn/usTp/7rE6f++x+3/ytn8/8rZ/P/K2fz/ytn8//L1/v////////////////8pZfH/KWXx/ydY6v8mTeT/Jk3kvwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACZN5M8mTeT/Jk3k/yZN5P9La+X/6+vr/+vr6//r6+v/6+vr/+vr6//r6+v/6+vr//Dw8P///////////////////////////////////////////zZv8v8pZfH/KFnr/yZN5P8mTeTPAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJk3k/yZN5P8mTeT/Jk3k/1d15v/r6+v/6+vr/+vr6//r6+v/6+vr/+vr6//r6+v/8PDw////////////////////////////////////////////X4z1/yll8f8oWev/Jk3k/yZN5P8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAmTeT/Jk3k/yZN5P8mTeT/V3Xm/+vr6//r6+v/6+vr/+vr6//r6+v/6+vr/+vr6//w8PD///////////////////////////////////////////9fjPX/KWXx/yhf7v8mTeT/Jk3k/wAAAAAAAAAAAAAAAAAAAAAAAAAAJk3kICZN5P8mTeT/Jk3k/yZN5P98kuf/6+vr/+vr6//r6+v/iZzo/yZN5P8mTeT/Jk3k/yZN5P8pZfH/KWXx/yll8f8pZfH/KWXx/yll8f8pZfH/KWXx/yll8f8pZfH/KF/u/yZN5P8mTeT/Jk3kIAAAAAAAAAAAAAAAAAAAAAAmTeRAJk3k/yZN5P8mTeT/Jk3k/4mc6P/r6+v/6+vr/+vr6/9Xdeb/Jk3k/yZN5P8mTeT/Jk3k/yll8f8pZfH/KWXx/yll8f8pZfH/KWXx/yll8f8pZfH/KWXx/yll8f8oYe//Jk3k/yZN5P8mTeRAAAAAAAAAAAAAAAAAAAAAACZN5EAmTeT/Jk3k/yZN5P8mTeT/iZzo/+vr6//r6+v/6+vr/1d15v8mTeT/Jk3k/yZN5P8mTeT/KWXx/yll8f8pZfH/KWXx/yll8f8pZfH/KWXx/yll8f8pZfH/KWXx/yll8f8mTeT/Jk3k/yZN5EAAAAAAAAAAAAAAAAAAAAAAJk3kcCZN5P8mTeT/Jk3k/yZN5P+6xOn/6+vr/+vr6//r6+v/obDo/4mc6P+JnOj/iZzo/4uf6v+Usvj/lLL4/5Sy+P+Usvj/lLL4/5Sy+P+Usvj/lLL4/3mf9v8pZfH/KWXx/yZN5P8mTeT/Jk3kcAAAAAAAAAAAAAAAAAAAAAAmTeSAJk3k/yZN5P8mTeT/Jk3k/7rE6f/r6+v/6+vr/+vr6//r6+v/6+vr/+vr6//r6+v/8PDw////////////////////////////////////////////ytn8/yll8f8pZfH/JlDm/yZN5P8mTeSAAAAAAAAAAAAAAAAAAAAAACZN5IAmTeT/Jk3k/yZN5P8mTeT/xs3q/+vr6//r6+v/6+vr/+vr6//r6+v/6+vr/+vr6//w8PD////////////////////////////////////////////K2fz/KWXx/yll8f8nU+f/Jk3k/yZN5IAAAAAAAAAAAAAAAAAAAAAAJk3kvyZN5P8mTeT/Jk3k/yZN5P/r6+v/6+vr/+vr6//r6+v/6+vr/+vr6//r6+v/6+vr//Dw8P////////////////////////////////////////////////8pZfH/KWXx/ydT5/8mTeT/Jk3kvwAAAAAAAAAAAAAAAAAAAAAmTeS/Jk3k/yZN5P8mTeT/Jk3k/1d15v9Xdeb/V3Xm/1d15v9Xdeb/V3Xm/1d15v9Xdeb/WXbn/1+M9f9fjPX/X4z1/1+M9f9fjPX/X4z1/1+M9f9fjPX/X4z1/yll8f8pZfH/J1jq/yZN5P8mTeS/AAAAAAAAAAAAAAAAAAAAACZN5M8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/KWXx/yll8f8pZfH/KWXx/yll8f8pZfH/KWXx/yll8f8pZfH/KWXx/yll8f8oWev/Jk3k/yZN5M8AAAAAAAAAAAAAAAAAAAAAJk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8pZfH/KWXx/yll8f8pZfH/KWXx/yll8f8pZfH/KWXx/yll8f8pZfH/KWXx/yhZ6/8mTeT/Jk3k/wAAAAAAAAAAAAAAAAAAAAAmTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yhf7v8oX+7/KF/u/yhf7v8oX+7/KF/u/yhf7v8oX+7/KF/u/yhf7v8oX+7/KFnr/yZN5P8mTeT/AAAAAAAAAAAAAAAAJk3kECZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeQQAAAAAAAAAAAmTeRAJk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5P8mTeT/Jk3k/yZN5EAAAAAA//w////AA//8AAA/8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/gAAAH4AAAB+AAAAfgAAAH4AAAB+AAAAfgAAAH4AAAB+AAAAfgAAAH4AAAB+AAAAfAAAADwAAAA8AAAAPAAAADwAAAA8AAAAPAAAADwAAAA8AAAAM=",what="raw")
