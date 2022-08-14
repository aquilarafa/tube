class App
  def call(env)
    sleep 5 if env["PATH_INFO"] == "/sleep"

    message = "Hello from the tube \npid:#{Process.pid}\n\n"
    [200, { "Content-Type" => "text/plain" }, [message]]
  end
end

run App.new
