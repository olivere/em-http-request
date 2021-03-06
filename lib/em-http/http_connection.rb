module EventMachine

  module HTTPMethods
    def get    options = {}, &blk;  setup_request(:get,   options, &blk); end
    def head   options = {}, &blk;  setup_request(:head,  options, &blk); end
    def delete options = {}, &blk;  setup_request(:delete,options, &blk); end
    def put    options = {}, &blk;  setup_request(:put,   options, &blk); end
    def post   options = {}, &blk;  setup_request(:post,  options, &blk); end
  end

  class FailedConnection
    include HTTPMethods
    include Deferrable

    attr_accessor :error, :opts

    def initialize(req)
      @opts = req
    end

    def setup_request(method, options)
      c = HttpClient.new(self, HttpOptions.new(@opts.uri, options, method), options)
      c.close(@error)
      c
    end
  end

  class HttpConnection < Connection
    include HTTPMethods
    include Deferrable
    include Socksify

    attr_accessor :error, :opts

    def setup_request(method, options = {})
      c = HttpClient.new(self, HttpOptions.new(@opts.uri, options, method), options)
      callback { c.connection_completed }

      middleware.each do |m|
        c.callback &m.method(:response) if m.respond_to?(:response)
      end

      @clients.push c
      c
    end

    def middleware
      [HttpRequest.middleware, @middleware].flatten
    end

    def post_init
      @clients = []
      @pending = []

      @middleware = []

      @p = Http::Parser.new
      @p.on_headers_complete = proc do |h|
        @clients.first.parse_response_header(h, @p.http_version, @p.status_code)
      end

      @p.on_body = proc do |b|
        @clients.first.on_body_data(b)
      end

      @p.on_message_complete = proc do
        if not @clients.first.continue?
          c = @clients.shift
          c.state = :finished
          c.on_request_complete
        end
      end
    end

    def use(klass, *args, &block)
      @middleware << klass.new(*args, &block)
    end

    def receive_data(data)
      begin
        @p << data
      rescue HTTP::Parser::Error => e
        c = @clients.shift
        c.on_error(e.message)
      end
    end

    def connection_completed
      if @opts.proxy && @opts.proxy[:type] == :socks5
        socksify(client.req.uri.host, client.req.uri.port, *@opts.proxy[:authorization]) { start }

      else
        start
      end
    end

    def start
      ssl = @opts.options[:tls] || @opts.options[:ssl] || {}
      start_tls(ssl) if client && client.ssl?

      succeed
    end

    def redirect(client, location)
      client.req.set_uri(location)
      @pending.push client
    rescue Exception => e
      client.on_error(e.message)
    end

    def unbind
      @clients.map {|c| c.unbind }

      if r = @pending.shift
        @clients.push r

        r.reset!
        @p.reset!

        begin
          set_deferred_status :unknown
          reconnect(r.req.host, r.req.port)
          callback { r.connection_completed }
        rescue EventMachine::ConnectionError => e
          @clients.pop.close(e.message)
        end
      end
    end

    private

      def client
        @clients.first
      end
  end
end
