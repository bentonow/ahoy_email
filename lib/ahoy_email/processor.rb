module AhoyEmail
  class Processor
    attr_reader :mailer, :options

    UTM_PARAMETERS = %w(utm_source utm_medium utm_term utm_content utm_campaign bento_identify bento_uuid)

    def initialize(mailer, options)
      @mailer = mailer
      @options = options

      unknown_keywords = options.keys - AhoyEmail.default_options.keys
      raise ArgumentError, "unknown keywords: #{unknown_keywords.join(", ")}" if unknown_keywords.any?
    end

    def perform
      track_open if options[:open]
      track_links if options[:utm_params] || options[:click]
      track_message
    end

    protected

    def message
      mailer.message
    end

    def token
      @token ||= SecureRandom.urlsafe_base64(32).gsub(/[\-_]/, "").first(32)
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

      if options[:open] || options[:click]
        data[:token] = token
      end

      if options[:utm_params]
        UTM_PARAMETERS.map(&:to_sym).each do |k|
          data[k] = options[k] if options[k]
        end
      end

      mailer.message.ahoy_data = data
    end

    def track_open
      if html_part?
        part = message.html_part || message
        raw_source = part.body.raw_source

        regex = /<\/body>/i
        regex_top = /<body.*?>/i

        url =
          url_for(
            controller: "ahoy/messages",
            action: "open",
            id: token,
            format: "gif"
          ).gsub("#{ENV['BASE_URL']}/ahoy/messages/", "#{options[:custom_domain]}/tracking/emails/")
        pixel = ActionController::Base.helpers.image_tag(url, size: "1x1", alt: "", style: "margin:0px!important;display:inherit;margin-bottom:0px")

        # try to add before body tag
        if raw_source.match(regex)
          part.body = raw_source.gsub(regex, "#{pixel}\\0")
        else
          part.body = raw_source + pixel
        end
        
        if options[:open_top]
          # try to add before body tag
          if raw_source.match(regex_top)
            part.body = raw_source.gsub(regex_top, "\\0#{pixel}")
          else
            # if the email does not have a body just do it normally.
            part.body = raw_source + pixel
          end
        end
      end
    end

    def track_links
      if html_part?
        part = message.html_part || message

        doc = Nokogiri::HTML(part.body.raw_source)
        doc.css("a[href]").each do |link|
          uri = parse_uri(link["href"])
          next unless trackable?(uri)
          # utm params first
          if options[:utm_params] && !skip_attribute?(link, "utm-params")
            params = uri.query_values(Array) || []
            UTM_PARAMETERS.each do |key|
              next if params.any? { |k, _v| k == key } || !options[key.to_sym]
              params << [key, options[key.to_sym]]
            end
            uri.query_values = params
            link["href"] = uri.to_s
          end

          if options[:click] && !skip_attribute?(link, "click")
            raise "Secret token is empty" unless AhoyEmail.secret_token

            # TODO sign more than just url and transition to HMAC-SHA256
            signature = OpenSSL::HMAC.hexdigest("SHA1", AhoyEmail.secret_token, link["href"])
            link["href"] =
              url_for(
                controller: "ahoy/messages",
                action: "click",
                id: token,
                url: link["href"],
                signature: signature
              ).gsub("#{ENV['BASE_URL']}/ahoy/messages/", "#{options[:custom_domain]}/tracking/emails/")
          end
        end

        part.body = doc.to_s
      end
    end

    def html_part?
      (message.html_part || message).content_type =~ /html/
    end

    def skip_attribute?(link, suffix)
      attribute = "data-skip-#{suffix}"

      skip_domains = ["twitter", "facebook", "fb.co", "https://t.co", "https://x.com", "http://t.co", "http://x.com", "tinyurl", 'bit.ly', 'owl.ly', 'dub.co', 'microsoft', 'netflix', 'amex']

      if link[attribute]
        # remove it
        link.remove_attribute(attribute)
        true
      elsif link["href"].present? && skip_domains.any? { |domain| link["href"].to_s.include?(domain) } 
        # avoid tracking specific phrases
        true
      else
        false
      end
    end

    # Filter trackable URIs, i.e. absolute one with http
    def trackable?(uri)
      uri && uri.absolute? && %w(http https).include?(uri.scheme)
    end

    # Parse href attribute
    # Return uri if valid, nil otherwise
    def parse_uri(href)
      # to_s prevent to return nil from this method
      Addressable::URI.heuristic_parse(href.to_s) rescue nil
    end

    def url_for(opt)
      opt = (ActionMailer::Base.default_url_options || {})
            .merge(options[:url_options])
            .merge(opt)
      AhoyEmail::Engine.routes.url_helpers.url_for(opt)
    end
  end
end
