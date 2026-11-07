/* Keep the demo session from bouncing.
   Demo mode calls some APIs with no bearer token. A 401 makes the UI
   decide the session expired, POST /auth/logout, and reload /login.
   This runs before the app and plants the dev-user cookie so /api/me
   stays authorized. If a demo 401 still reaches /api/me, answer 200 so
   the expiry handler keeps the page up. */
(function () {
  try {
    var xhr = new XMLHttpRequest()
    xhr.open('GET', '/auth/github', false)
    xhr.withCredentials = true
    xhr.send(null)
  } catch (e) {}

  if (!window.fetch) return
  var orig = window.fetch
  window.fetch = function (input, init) {
    return orig.call(window, input, init).then(function (res) {
      if (res.status !== 401) return res
      var url = typeof input === 'string' ? input : (input && input.url) || ''
      var demo = true
      try {
        demo = localStorage.getItem('kc-demo-mode') !== 'false'
      } catch (e) {}
      if (!demo || url.indexOf('/api/me') === -1) return res
      return new Response('{}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' }
      })
    })
  }
})()
