# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

lua_compile(NAME http FILES http.lua http_utils.lua)
lua_install(TARGET http DESTINATION ${MODULE_INSTALL_PATH}/protocol)

# Tests
add_subdirectory(test)
