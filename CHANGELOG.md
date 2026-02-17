# Changelog

## [1.2.0](https://github.com/wsdjeg/chat.nvim/compare/v1.1.0...v1.2.0) (2026-02-17)


### Features

* add `:Chat clear` command ([6aae8b9](https://github.com/wsdjeg/chat.nvim/commit/6aae8b97a07ff4f9982da3708064c8c2a1e211f1))
* add `:Chat delete` command ([332e09c](https://github.com/wsdjeg/chat.nvim/commit/332e09cb3dacfa5784c3be19a342faa8206c7c72))
* add `find_files` tool ([28173d4](https://github.com/wsdjeg/chat.nvim/commit/28173d43ebfce10d985955284da997c80880aa3b))
* add bigmodel provider ([67a2b2a](https://github.com/wsdjeg/chat.nvim/commit/67a2b2a8855233b2c1d40a9b0bf8262a9b4937dd))
* add key-bindings for picker chat ([2c92e59](https://github.com/wsdjeg/chat.nvim/commit/2c92e598c3ef722b7ce59a2cd5ab7de4d3c01179))
* add memory support ([50bf112](https://github.com/wsdjeg/chat.nvim/commit/50bf112bead3f2cc08a34ca24ed2bf3e1457959c))
* add openai support ([10c1f10](https://github.com/wsdjeg/chat.nvim/commit/10c1f1080fa940f86573949c43be9c90c10d7272))
* add progress spinners ([fbfac0e](https://github.com/wsdjeg/chat.nvim/commit/fbfac0e774beb68ff01c2d9cd2116dcfcffa3d61))
* add qwen provider ([cadb33b](https://github.com/wsdjeg/chat.nvim/commit/cadb33bd0de544fa9f4c8480122067198e0ffb4f))
* add search_text tool ([f851fc7](https://github.com/wsdjeg/chat.nvim/commit/f851fc7326b55101ef63d5a8e6e114df7f1ce233))
* add siliconflow provider ([b1d7046](https://github.com/wsdjeg/chat.nvim/commit/b1d70463a9a58ecd7c44cb7ae8b4953243c8b9de))
* add tencent provider ([ce039b1](https://github.com/wsdjeg/chat.nvim/commit/ce039b1627c39e2e0df15bd418de0d5831c798e6))
* add volcengine provider ([097f4c2](https://github.com/wsdjeg/chat.nvim/commit/097f4c2bbde17a30c916b7cd4f875abc6348da5d))
* highlight time as Comment ([2542b95](https://github.com/wsdjeg/chat.nvim/commit/2542b953481d50c9e59bd0d04b08e4716e5bf515))
* improve chat.log module ([13165a9](https://github.com/wsdjeg/chat.nvim/commit/13165a923f55b9df333e80b2c37aa87552e5150d))
* support multiple session requesting ([62eff4c](https://github.com/wsdjeg/chat.nvim/commit/62eff4cb750e0b09e5c8c074beef6a7985c14aa6))
* support read_file range ([f40c31d](https://github.com/wsdjeg/chat.nvim/commit/f40c31d29f3d5fd5571ab6e2b5272f64cc0ad471))
* support session.cwd ([baa42ca](https://github.com/wsdjeg/chat.nvim/commit/baa42ca6b107c57b099bc85f0492836be9aef04d))
* support setting allowed_path to table ([f3ba482](https://github.com/wsdjeg/chat.nvim/commit/f3ba48266a09dc2e30b0663a2d45db7a1137fa22))
* use ctrl-n to create new session ([474ea9f](https://github.com/wsdjeg/chat.nvim/commit/474ea9f8ef0e4498b98eb6c8f4c35f45013548a6))


### Bug Fixes

* add is_thinking flag ([64cd771](https://github.com/wsdjeg/chat.nvim/commit/64cd7710324845e3f7360df5e7cbc711c28cb734))
* add new line before content after reasoning ([181a7d0](https://github.com/wsdjeg/chat.nvim/commit/181a7d080ce5b79027a936cd220642617fbf4c3a))
* always lost last usage ([d9c3cc6](https://github.com/wsdjeg/chat.nvim/commit/d9c3cc6aeae671bd51368619747cef685c2996ba))
* and extra empty line ([00796e3](https://github.com/wsdjeg/chat.nvim/commit/00796e355f2bfeedf9489f5f58765c3423a8afef))
* append failed tool call to message ([75aaea1](https://github.com/wsdjeg/chat.nvim/commit/75aaea1799d5618acd7ceaf2768840174bac50e3))
* check if arguments is vim.NIL ([bc964c6](https://github.com/wsdjeg/chat.nvim/commit/bc964c6946e2636155a7f7d95f650eb411a2291c))
* clear job_tool_calls by id ([dc9347b](https://github.com/wsdjeg/chat.nvim/commit/dc9347bbc3b2e9f9dc25b95a35b9b94e56dd5fbd))
* complete `delete` in cmdline ([1593fff](https://github.com/wsdjeg/chat.nvim/commit/1593fffd3eaaedcff92394de8c4bb04185c1cc5e))
* correct sse handle ([1b39c93](https://github.com/wsdjeg/chat.nvim/commit/1b39c930d88ed904038f7fdd2ed0f038b9d90bf7))
* delete memory when delete session ([b9c4828](https://github.com/wsdjeg/chat.nvim/commit/b9c482804017223535b19c2ea82a1716df323f9c))
* enable number option in result/prompt win ([34bff91](https://github.com/wsdjeg/chat.nvim/commit/34bff9194198aa89e80c4cfc6130637ca3a4c224))
* fix allowed_path checking ([8c1ef83](https://github.com/wsdjeg/chat.nvim/commit/8c1ef8341946246512b2eb8b9b7048e8daece3e3))
* fix chat delete command ([1e14a9e](https://github.com/wsdjeg/chat.nvim/commit/1e14a9e4f26761502655605b033ecd2625b9df15))
* fix error time highlight ([d2fbb57](https://github.com/wsdjeg/chat.nvim/commit/d2fbb5771f4c1a8827d07f6e8b88411027a5c9aa))
* fix json decode error ([51ba050](https://github.com/wsdjeg/chat.nvim/commit/51ba0504f4000a9b338e4669726cceb4e857b627))
* fix list models of moonshot ([9f03b38](https://github.com/wsdjeg/chat.nvim/commit/9f03b38e414e3f976643764d8aabfb27baec05e7))
* fix moonshot support ([5b121b1](https://github.com/wsdjeg/chat.nvim/commit/5b121b1a66c7c5cd51390f9f9f5b37f124dc0962))
* fix multiple tool calls ([a614ec9](https://github.com/wsdjeg/chat.nvim/commit/a614ec9454ea46c84952d7fd0cd47dffc8b69c30))
* fix thinking position ([911c48b](https://github.com/wsdjeg/chat.nvim/commit/911c48b94735b3b613c13e088bff54d80a8df70d))
* fix unknown config ([07bb72f](https://github.com/wsdjeg/chat.nvim/commit/07bb72f8be446efa3c5094dd0486c58af4cd0323))
* fix unknown message ([20a3ef2](https://github.com/wsdjeg/chat.nvim/commit/20a3ef24bbf4e9f8f9db52f141ac9271bdf94c6e))
* fix wrong tokens ([e9bafbc](https://github.com/wsdjeg/chat.nvim/commit/e9bafbca910bbbfdab19a587ab0b99a8bdcf51e1))
* format UI messages ([f0560b2](https://github.com/wsdjeg/chat.nvim/commit/f0560b26d52059f247c5b341813816e8092dbdf9))
* handle content and reasoning_content ([488cb73](https://github.com/wsdjeg/chat.nvim/commit/488cb73dcd9c1bb033872e6a2cdd0e94cb0df4b1))
* improve code in sessions ([c7eb66b](https://github.com/wsdjeg/chat.nvim/commit/c7eb66b1ec5931119dd2aad16f62ec188bef24a6))
* improve on_exit function ([6dcb5da](https://github.com/wsdjeg/chat.nvim/commit/6dcb5da1d528186b71ac160d53381677b896e489))
* make sure on_progress_exit is called later ([f6a7b0f](https://github.com/wsdjeg/chat.nvim/commit/f6a7b0fc9c375b9789eedb9a325b64fd598d347a))
* make sure tool_calls is not vim.NIL ([20a2406](https://github.com/wsdjeg/chat.nvim/commit/20a2406a7eb57fe54b86042dc2b6f805abd5b2e0))
* only log none empty line ([cd2acba](https://github.com/wsdjeg/chat.nvim/commit/cd2acba4ea1a52a9096a724ae3c4e9353b3f4917))
* remove usage debug line ([55a1cb0](https://github.com/wsdjeg/chat.nvim/commit/55a1cb043a1450d4b01b799b1bc65f37b4a59ae9))
* set current provider only when session exist ([c1c7df2](https://github.com/wsdjeg/chat.nvim/commit/c1c7df2360b7afc33e4a385b07f2365e36ed61af))
* tool_calls message ([2e2a31e](https://github.com/wsdjeg/chat.nvim/commit/2e2a31ea6c1c7e00538f79ca123349be0550148a))
* unique time key ([3f89995](https://github.com/wsdjeg/chat.nvim/commit/3f89995ae4280eda6ece00f3a4ea46c0ac5e7fc7))
* use stdout/stderr debug ([35902fd](https://github.com/wsdjeg/chat.nvim/commit/35902fdfd285d5c7e6991c0437973e4c89d5c414))
* **window:** disable result window linebreak ([8d601da](https://github.com/wsdjeg/chat.nvim/commit/8d601dafab41c336b62af4bcfe079670d1d312fe))

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
