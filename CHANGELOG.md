# Changelog

## [1.1.0](https://github.com/wsdjeg/chat.nvim/compare/v1.0.0...v1.1.0) (2026-02-09)


### Features

* add `:Chat new` to create new session ([f64eb16](https://github.com/wsdjeg/chat.nvim/commit/f64eb16cd4eaab6347ddc572e237a1b05cb3b53e))
* add `:Chat next/prev` commands ([e53604f](https://github.com/wsdjeg/chat.nvim/commit/e53604f85d123004e590ad7c1e6c49a6155dba0e))
* add `alt-h/l` key bindings to change session ([a91b037](https://github.com/wsdjeg/chat.nvim/commit/a91b0376e1d43e38ae6de893ebcf1808f5254e4b))
* add `github` provider for github.ai ([08da8b6](https://github.com/wsdjeg/chat.nvim/commit/08da8b6199a4c9b5c0a87eda5e31d55fc50d3cef))
* add chat windows ([6ee15f7](https://github.com/wsdjeg/chat.nvim/commit/6ee15f780ac388bddc87b0659262d43cc714be4b))
* add chat_model source ([b54c147](https://github.com/wsdjeg/chat.nvim/commit/b54c147089d83f9ff10aa8b5606bfaab8d34c99b))
* add chat.log module ([d10f75c](https://github.com/wsdjeg/chat.nvim/commit/d10f75cdfa3c07cf53d8e5384ca7fdc8bca23908))
* add moonshot provider ([fa126d5](https://github.com/wsdjeg/chat.nvim/commit/fa126d5ff94830a4128523c19b87c7b0b8de7381))
* add openrouter provider ([fa2b146](https://github.com/wsdjeg/chat.nvim/commit/fa2b146ac8c79bbeaa4d472213b00fc1556e8b92))
* add picker chat_provider source ([c657006](https://github.com/wsdjeg/chat.nvim/commit/c65700642317ab8c26937fa0f5438475d77356f2))
* add picker-chat source ([f363119](https://github.com/wsdjeg/chat.nvim/commit/f363119a31f8082e60e1c1abd32316d365b23b3a))
* add sessions support ([44ac3ae](https://github.com/wsdjeg/chat.nvim/commit/44ac3ae4e134d2e2a2c5b254aed111041e4f6028))
* add tools support ([72fb859](https://github.com/wsdjeg/chat.nvim/commit/72fb859a8f986e5a0e42ee79dc2427544f3bb132))
* add user command completion ([35b204b](https://github.com/wsdjeg/chat.nvim/commit/35b204b171013727f46acbe48af5659a8fb25b79))
* add windows title ([e2869bd](https://github.com/wsdjeg/chat.nvim/commit/e2869bdc196781a9e091d4d792d15daa79e884b3))
* AI help you to setup chat.nvim ([79265c3](https://github.com/wsdjeg/chat.nvim/commit/79265c3ff2828de5a2c8b9c68bd30b7547ce3591))
* handle api error chunk ([808f391](https://github.com/wsdjeg/chat.nvim/commit/808f39127b94224d816dda40afd9997353869bbd))
* make provider request function return jobid ([a6adbfd](https://github.com/wsdjeg/chat.nvim/commit/a6adbfd3d647472c4d86d4dea894f35ff79c0210))
* support config border ([99b905b](https://github.com/wsdjeg/chat.nvim/commit/99b905b7fc1cf6ebf42a4605a24b9c3ad302dfe9))
* support custom tools ([29dbe03](https://github.com/wsdjeg/chat.nvim/commit/29dbe03e338e3ec9a6b30ca7f3eacb9e498ab4e8))
* support displaying token usage ([35c5bfa](https://github.com/wsdjeg/chat.nvim/commit/35c5bfa194d30619eabd52888fcf8ec7f63a65fa))
* support retry after cancel requesting ([ea10753](https://github.com/wsdjeg/chat.nvim/commit/ea107530b969f87aff687cdd33bcdac74093670a))
* support stream handle ([7101d62](https://github.com/wsdjeg/chat.nvim/commit/7101d626b9ed28bbe8d0c13eaae6245db5d8876b))
* use setup to change api_key and provider ([d5e7be2](https://github.com/wsdjeg/chat.nvim/commit/d5e7be256df1e9e223b8560c4311e389344f6f59))


### Bug Fixes

* check moonshot and github api_key ([77474dc](https://github.com/wsdjeg/chat.nvim/commit/77474dccbf6db87a36bee88eefb2b35f0241b00e))
* clear previous content ([dedbe1a](https://github.com/wsdjeg/chat.nvim/commit/dedbe1a5742d06295e168125ef6ef9a72aaeacd2))
* enable wrap in result window ([ab1697d](https://github.com/wsdjeg/chat.nvim/commit/ab1697d39da3b48d5d8565afc82521320efad212))
* fix deepseek api_key ([27de798](https://github.com/wsdjeg/chat.nvim/commit/27de79828560d684ccac931371c4fa2a9fa62db7))
* fix setup function ([2001b6c](https://github.com/wsdjeg/chat.nvim/commit/2001b6cf5ee825776b90e755a84268fce057036d))
* fix user message ([a81fd32](https://github.com/wsdjeg/chat.nvim/commit/a81fd32cafc2e5f94418385db6b0c6862fdd6240))
* handle error response ([fddf4b0](https://github.com/wsdjeg/chat.nvim/commit/fddf4b0e9377a8a9cf5fc5bd0fe6c14907adfafe))
* handle http error ([aebc5dc](https://github.com/wsdjeg/chat.nvim/commit/aebc5dcf28ca64d1da10530e34acc41c7b884d60))
* handle json parse error ([6540cfb](https://github.com/wsdjeg/chat.nvim/commit/6540cfb8c1a7af804ef330cea131e6e988be35b1))
* improve message UI ([c80c6aa](https://github.com/wsdjeg/chat.nvim/commit/c80c6aae83bddcee683af4e62b95733b05cf2231))
* make sure the buf prompt_win is prompt_buf ([cf57ddb](https://github.com/wsdjeg/chat.nvim/commit/cf57ddbe84ed27c9c9047124e25246fbd09d15a7))
* remove extra space on result_buf ([46e704d](https://github.com/wsdjeg/chat.nvim/commit/46e704d6c5d1aa667229867275da0ee23691f64a))
* remove unsupported thinking ([4b34ef3](https://github.com/wsdjeg/chat.nvim/commit/4b34ef3932ae72b333c6123082de33a8ee8345d5))
* send tool_call error to AI ([a8ecb17](https://github.com/wsdjeg/chat.nvim/commit/a8ecb17816c0a06525c763e8d3cf86d65225c4c9))
* setup will clear api-key ([18b7106](https://github.com/wsdjeg/chat.nvim/commit/18b71061d57a63bd17cc46aa049d07dd1d48b073))
* use stdin to send body ([3f42776](https://github.com/wsdjeg/chat.nvim/commit/3f427762779ff9ffe645fd6683195da0b234731d))

## 1.0.0 (2026-02-02)


### Features

* init version ([2f9c580](https://github.com/wsdjeg/chat.nvim/commit/2f9c580ed161ccca6ffdbb61a6a6be08aa5d9b16))
