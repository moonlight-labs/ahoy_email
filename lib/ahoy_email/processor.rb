module AhoyEmail
  class Processor
    attr_reader :mailer, :options

    UTM_PARAMETERS = %w[utm_source utm_medium utm_term utm_content utm_campaign].freeze

    def initialize(mailer, options)
      @mailer = mailer
      @options = options

      unknown_keywords = options.keys - AhoyEmail.default_options.keys
      raise ArgumentError, "unknown keywords: #{unknown_keywords.join(', ')}" if unknown_keywords.any?
    end

    def perform
      track_open if options[:open]
      track_open_ga if options[:google_analytics_code]
      track_links if options[:utm_params] || options[:click]
      track_special_links if options[:special_links]
      track_message
    end

    protected

    def message
      mailer.message
    end

    def token
      @token ||= SecureRandom.urlsafe_base64(32).gsub(/[\-_]/, '').first(32).downcase
    end

    def track_message
      data = {
        mailer: options[:mailer],
        extra: options[:extra],
        user: options[:user]
      }

      # legacy, remove in next major version
      user = options[:user]
      if user
        data[:user_type] = user.model_name.name
        id = user.id
        data[:user_id] = id.is_a?(Integer) ? id : id.to_s
      end

      data[:token] = token if options[:open] || options[:click]

      if options[:utm_params]
        UTM_PARAMETERS.map(&:to_sym).each do |k|
          data[k] = options[k] if options[k]
        end
      end

      mailer.message.ahoy_data = data
    end

    def track_open
      if html_part?
        raw_source = (message.html_part || message).body.raw_source
        regex = /<\/body>/i
        url =
          url_for(
            controller: 'ahoy/messages',
            action: 'open',
            id: token,
            format: 'gif'
          )
        pixel = ActionController::Base.helpers.image_tag(url, size: '1x1', alt: '')

        # try to add before body tag
        if raw_source.match(regex)
          raw_source.gsub!(regex, "#{pixel}\\0")
        else
          raw_source << pixel
        end
      end
    end

    def track_open_ga
      if html_part?
        raw_source = (message.html_part || message).body.raw_source
        regex = /<\/body>/i

        epath = "/email/#{mailer.mailer_name}/#{mailer.action_name}"

        tracker = {
          v: 1,
          tid: options[:google_analytics_code],
          cid: 555,
          t: :pageview,
          # t: :event,
          # ec: :email,
          # ea: :open,
          # el: epath,
          dp: epath
        }

        url = "https://www.google-analytics.com/collect?#{tracker.to_query}"
        pixel = ActionController::Base.helpers.image_tag(url, size: '1x1', alt: '')

        # try to add before body tag
        if raw_source.match(regex)
          raw_source.gsub!(regex, "#{pixel}\\0")
        else
          raw_source << pixel
        end
      end
    end

    def track_links
      if html_part?
        body = (message.html_part || message).body

        doc = Nokogiri::HTML(body.raw_source)
        doc.css('a[href]').each do |link|
          uri = parse_uri(link['href'])
          next unless trackable?(uri)

          # utm params first
          if options[:utm_params] && !skip_attribute?(link, 'utm-params')
            params = uri.query_values(Array) || []
            UTM_PARAMETERS.each do |key|
              next if params.any? { |k, _v| k == key } || !options[key.to_sym]

              params << [key, options[key.to_sym]]
            end
            uri.query_values = params
            link['href'] = uri.to_s
          end

          next unless options[:click] && !skip_attribute?(link, 'click')

          # TODO: sign more than just url and transition to HMAC-SHA256
          signature = OpenSSL::HMAC.hexdigest('SHA1', AhoyEmail.secret_token, link['href'])
          link['href'] =
            url_for(
              controller: 'ahoy/messages',
              action: 'click',
              id: token,
              url: link['href'],
              signature: signature
            )
        end

        # hacky
        body.raw_source.sub!(body.raw_source, doc.to_s)
      end
    end

    def track_special_links
      if html_part?
        body = (message.html_part || message).body

        doc = Nokogiri::HTML(body.raw_source)
        doc.css('a[href]').each do |link|
          uri = parse_uri(link['href'])
          next unless trackable?(uri)

          link['href'] = link['href'].gsub("%7B%7BMSGTOKEN%7D%7D", token)
        end

        # hacky
        body.raw_source.sub!(body.raw_source, doc.to_s)
      end
    end

    def html_part?
      (message.html_part || message).content_type =~ /html/
    end

    def skip_attribute?(link, suffix)
      attribute = "data-skip-#{suffix}"
      if link[attribute]
        # remove it
        link.remove_attribute(attribute)
        true
      elsif link['href'].to_s =~ /unsubscribe/i && !options[:unsubscribe_links]
        # try to avoid unsubscribe links
        true
      else
        false
      end
    end

    # Filter trackable URIs, i.e. absolute one with http
    def trackable?(uri)
      uri && uri.absolute? && %w[http https].include?(uri.scheme)
    end

    # Parse href attribute
    # Return uri if valid, nil otherwise
    def parse_uri(href)
      # to_s prevent to return nil from this method

      Addressable::URI.heuristic_parse(href.to_s)
    rescue StandardError
      nil
    end

    def url_for(opt)
      opt = (ActionMailer::Base.default_url_options || {})
            .merge(options[:url_options])
            .merge(opt)
      AhoyEmail::Engine.routes.url_helpers.url_for(opt)
    end
  end
end
