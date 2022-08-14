require "socket"
require "http/parser"
require "stringio"
require "thread"
require "eventmachine"

class Tube
  def initialize(port, app)
    @server = TCPServer.new(port)
    @app = app
    @port = port
  end

  def prefork(workers_count)
    workers_count.times do
      fork do
        puts "Forked pid:#{Process.pid}"
        start
      end
    end
    Process.waitall
  end

  def start
    loop do
      socket = @server.accept
      Thread.new do
        connection = Connection.new(socket, @app)
        connection.process
      end
    end
  end

  def start_em
    EventMachine.run do
      EventMachine.start_server "localhost", @port, EMConnection do |connection|
        connection.app = @app
      end
    end
  end

  class Connection
    def initialize(socket, app)
      @socket = socket
      @parser = Http::Parser.new(self)
      @app = app
    end

    def process
      until @socket.closed? || @socket.eof?
        data = @socket.readpartial(1024)
        puts "[read stream]"
        puts "   " + data
        @parser << data
      end
    end

    def on_message_complete
      env = create_rack_env

      send_response env
    end

    def send_response(env)
      status, headers, body = @app.call(env)

      reason = get_status_code_reason(status)

      @socket.write "HTTP/1.1 #{status} #{reason}\r\n"
      headers.each_pair { |name, value| @socket.write "#{name}: #{value}\r\n" }
      @socket.write "\r\n"
      body.each { |chunk| @socket.write "#{chunk}" }

      body.close if body.respond_to? :close
      close
    end

    def create_rack_env
      env = {}
      @parser.headers.each_pair do |name, value|
        name = "HTTP_" + name.upcase.tr("-", "_")
        env[name] = value
      end
      env["PATH_INFO"] = @parser.request_url
      env["REQUEST_METHOD"] = @parser.http_method
      env["rack.input"] = StringIO.new
      env
    end

    def get_status_code_reason(status_code)
      reasons = { 200 => "OK", 400 => "Not Found" }
      reason = reasons[status_code]
    end

    def close
      @socket.close
    end
  end

  class EMConnection < EventMachine::Connection
    attr_accessor :app

    def post_init
      @parser = Http::Parser.new(self)
    end

    def receive_data(data)
      @parser << data
    end

    def on_message_complete
      env = create_rack_env

      send_response env
    end

    def send_response(env)
      status, headers, body = @app.call(env)

      reason = get_status_code_reason(status)

      send_data "HTTP/1.1 #{status} #{reason}\r\n"
      headers.each_pair { |name, value| send_data "#{name}: #{value}\r\n" }
      send_data "\r\n"
      body.each { |chunk| send_data chunk }
      body.close if body.respond_to? :close
      close_connection_after_writing
    end

    def create_rack_env
      env = {}
      @parser.headers.each_pair do |name, value|
        name = "HTTP_" + name.upcase.tr("-", "_")
        env[name] = value
      end
      env["PATH_INFO"] = @parser.request_url
      env["REQUEST_METHOD"] = @parser.http_method
      env["rack.input"] = StringIO.new
      env
    end

    def get_status_code_reason(status_code)
      reasons = { 200 => "OK", 400 => "Not Found" }
      reason = reasons[status_code]
    end
  end

  class Builder
    attr_reader :app

    def run(app)
      @app = app
    end

    def self.parse_file(file)
      content = File.read(file)
      builder = self.new
      builder.instance_eval content
      builder.app
    end
  end
end

app = Tube::Builder.parse_file("config.ru")
server = Tube.new(3000, app)
puts "[server] listening..."

# One process with multiples threads for requests
# server.start

# Worker processes with multiples threads
# server.prefork 4

# Blocking event loop
server.start_em
