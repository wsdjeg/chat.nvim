local lu = require('luaunit')
local response = require('chat.http.response')

local function fake_client()
  return {
    closing = false,
    written = nil,
    closed = false,
    is_closing = function(self) return self.closing end,
    write = function(self, data, cb)
      self.written = data
      if cb then cb() end
    end,
    close = function(self) self.closed = true end,
  }
end

TestHttpResponse = {}

function TestHttpResponse:testParseHeaders()
  local headers = response.parse_headers('Content-Type: application/json\r\nX-Foo: bar\r\n')
  lu.assertEquals('application/json', headers['content-type'])
  lu.assertEquals('bar', headers['x-foo'])
end

function TestHttpResponse:testParseHeadersIgnoresNonHeader()
  local headers = response.parse_headers('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n')
  lu.assertEquals('text/plain', headers['content-type'])
  lu.assertNil(headers['http/1.1 200 ok'])
end

function TestHttpResponse:testParseHeadersEmpty()
  local headers = response.parse_headers('')
  lu.assertEquals({}, headers)
end

function TestHttpResponse:testUrlDecode()
  lu.assertEquals('hello world', response.url_decode('hello%20world'))
  lu.assertEquals('a/b', response.url_decode('a%2Fb'))
  lu.assertEquals('plain', response.url_decode('plain'))
end

function TestHttpResponse:testSendRaw()
  local c = fake_client()
  response.send_raw(c, 200, 'text/plain', 'hello')
  lu.assertStrContains(c.written, 'HTTP/1.1 200 OK')
  lu.assertStrContains(c.written, 'Content-Type: text/plain')
  lu.assertStrContains(c.written, 'hello')
  lu.assertTrue(c.closed)
end

function TestHttpResponse:testSendRawUnknownStatus()
  local c = fake_client()
  response.send_raw(c, 999, 'text/plain', 'x')
  lu.assertStrContains(c.written, '999 Unknown')
end

function TestHttpResponse:testSendJson()
  local c = fake_client()
  response.send_json(c, 200, { hello = 'world' })
  lu.assertStrContains(c.written, 'application/json')
  lu.assertStrContains(c.written, '"hello":"world"')
  lu.assertTrue(c.closed)
end

function TestHttpResponse:testSendError()
  local c = fake_client()
  response.send_error(c, 404, 'not found')
  lu.assertStrContains(c.written, '404 Not Found')
  lu.assertStrContains(c.written, '"error":"not found"')
end

function TestHttpResponse:testSendResponse()
  local c = fake_client()
  response.send_response(c, 204, 'No Content')
  lu.assertStrContains(c.written, '204 No Content')
  lu.assertStrContains(c.written, 'Content-Length: 0')
end

function TestHttpResponse:testSendResponseDefaultText()
  local c = fake_client()
  response.send_response(c, 200)
  lu.assertStrContains(c.written, '200 OK')
end

function TestHttpResponse:testWriteAndCloseNilClient()
  -- Should not error
  response.send_json(nil, 200, {})
  lu.assertTrue(true)
end

function TestHttpResponse:testWriteAndCloseAlreadyClosing()
  local c = fake_client()
  c.closing = true
  response.send_json(c, 200, {})
  lu.assertNil(c.written)
end

function TestHttpResponse:testWriteAndCloseWriteFails()
  local c = fake_client()
  c.write = function() error('write failed') end
  response.send_json(c, 200, {})
  lu.assertTrue(c.closed)
end

return TestHttpResponse
