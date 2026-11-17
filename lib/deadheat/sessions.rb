module Deadheat
  # Gives every racing actor its own browser session (cookies, signed-in user) and puts that session
  # back to the same starting point before each try.
  class Sessions
    Prepared = Struct.new(:spec, :session, :cookies)

    def self.label_for(record)
      name = %i[name username email login].lazy.map { |attribute| record.try(attribute) }.find(&:present?)
      name ? name.to_s : "#{record.class.model_name.human.downcase} #{record.id}"
    end

    def initialize(context, specs)
      @context = context
      @prepared = specs.map { |spec| prepare(spec) }
    end

    def size
      @prepared.size
    end

    def names
      @prepared.map { |prepared| prepared.spec[:label] }
    end

    # Fresh actors for one run: same sessions, cookies reset to how they were after signing in.
    def actors
      @prepared.each_with_index.map do |prepared, index|
        Actor.new(name: prepared.spec[:label], index: index, block: runner(prepared))
      end
    end

    private

    def prepare(spec)
      return Prepared.new(spec, nil, nil) unless spec[:http]

      session = @context.open_session
      session.integration_session.host = spec[:host] if spec[:host]
      session.integration_session.https!(spec[:https]) unless spec[:https].nil?
      mock(session).cookie_jar = spec[:cookies].dup if spec[:cookies]
      user = spec[:user]
      user = @context.instance_exec(&user) if user.respond_to?(:call) # sign_in: -> { @alice }, after setup
      sign_in(session, user) if user
      Prepared.new(spec, session, jar(session).dup)
    end

    def runner(prepared)
      block = prepared.spec[:block]
      if prepared.session
        session = prepared.session
        cookies = prepared.cookies
        lambda do
          mock(session).cookie_jar = cookies.dup
          session.instance_exec(&block)
          session.response
        end
      else
        context = @context
        -> { Rails.application.executor.wrap { context.instance_exec(&block) } }
      end
    end

    def mock(session)
      session.integration_session.send(:_mock_session)
    end

    def jar(session)
      mock(session).cookie_jar
    end

    def sign_in(session, user)
      hook = Deadheat.config.sign_in_hook
      if hook
        session.instance_exec(user, &hook)
      elsif session.respond_to?(:sign_in_as)
        session.sign_in_as(user) # the helper Rails 8's authentication generator writes
      elsif defined?(Warden::Test::Helpers) && session.respond_to?(:sign_in)
        devise_sign_in(session, user)
      else
        raise Refused, <<~TEXT.squish
          Dead Heat doesn't know how this app signs users in. Tell it once, in test/races/race_helper.rb:
          Deadheat.configure { |c| c.sign_in { |user| post login_path, params: { email: user.email, password: "secret" } } }
        TEXT
      end
    end

    # Devise queues the login for the next request in a list shared by every thread, so each session
    # signs in alone, with a warm-up request, before any racing starts.
    def devise_sign_in(session, user)
      session.sign_in(user)
      session.get(Ping::PATH)
      return if session.response&.status == 204

      raise Refused, "Signing in #{Sessions.label_for(user)} didn't work: the warm-up request got #{session.response&.status.inspect}. Dead Heat adds the /__deadheat/ping route in the test environment; does a catch-all route earlier in config/routes.rb take it?"
    end
  end
end
