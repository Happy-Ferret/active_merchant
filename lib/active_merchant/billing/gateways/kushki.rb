module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class KushkiGateway < Gateway
      self.display_name = "Kushki"
      self.homepage_url = "https://www.kushkipagos.com"

      self.test_url = "https://api-uat.kushkipagos.com/v1/"
      self.live_url = "https://api.kushkipagos.com/v1/"

      self.supported_countries = ["CO", "EC"]
      self.default_currency = "USD"
      self.money_format = :dollars
      self.supported_cardtypes = [:visa, :master, :american_express, :discover, :diners_club]

      def initialize(options={})
        requires!(options, :public_merchant_id, :private_merchant_id)
        super
      end

      def purchase(amount, payment_method, options={})
        MultiResponse.run() do |r|
          r.process { tokenize(amount, payment_method, options) }
          r.process { charge(amount, r.authorization, options) }
        end
      end

      def void(authorization, options={})
        action = "void"

        post = {}
        add_invoice(action, post, nil, options)

        commit(action, post, authorization)
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(%r((Private-Merchant-Id: )\d+), '\1[FILTERED]').
          gsub(%r((\"card\\\":{\\\"number\\\":\\\")\d+), '\1[FILTERED]').
          gsub(%r((\"cvv\\\":\\\")\d+), '\1[FILTERED]')
      end

      private

      def tokenize(amount, payment_method, options)
        action = "tokenize"

        post = {}
        add_invoice(action, post, amount, options)
        add_payment_method(post, payment_method, options)

        commit(action, post)
      end

      def charge(amount, authorization, options)
        action = "charge"

        post = {}
        add_reference(post, authorization, options)
        add_invoice(action, post, amount, options)

        commit(action, post)
      end

      def add_invoice(action, post, money, options)
        if action == "tokenize"
          post[:totalAmount] = amount(money).to_f
          post[:currency] = options[:currency] || currency(money)
          post[:isDeferred] = false
        else
          sum = {}
          sum[:currency] = options[:currency] || currency(money)
          add_amount_defaults(sum, money, options)
          add_amount_by_country(sum, options)
          post[:amount] = sum
        end
      end

      def add_amount_defaults(sum, money, options)
        sum[:subtotalIva] = amount(money).to_f
        sum[:iva] = 0
        sum[:subtotalIva0] = 0

        if sum[:currency] == "COP"
          extra_taxes = {}
          extra_taxes[:propina] = 0
          extra_taxes[:tasaAeroportuaria] = 0
          extra_taxes[:agenciaDeViaje] = 0
          extra_taxes[:iac] = 0
          sum[:extraTaxes] = extra_taxes
        else
          sum[:ice] = 0
        end
      end

      def add_amount_by_country(sum, options)
        if amount = options[:amount]
          sum[:subtotalIva] = amount[:subtotal_iva].to_f if amount[:subtotal_iva]
          sum[:iva] = amount[:iva].to_f if amount[:iva]
          sum[:subtotalIva0] = amount[:subtotal_iva_0].to_f if amount[:subtotal_iva_0]
          sum[:ice] = amount[:ice].to_f if amount[:ice]
          if extra_taxes = amount[:extra_taxes] && sum[:currency] == "COP"
            sum[:extraTaxes][:propina] = extra_taxes[:propina].to_f if extra_taxes[:propina]
            sum[:extraTaxes][:tasaAeroportuaria] = extra_taxes[:tasa_aeroportuaria].to_f if extra_taxes[:tasa_aeroportuaria]
            sum[:extraTaxes][:agenciaDeViaje] = extra_taxes[:agencia_de_viaje].to_f if extra_taxes[:agencia_de_viaje]
            sum[:extraTaxes][:iac] = extra_taxes[:iac].to_f if extra_taxes[:iac]
          end
        end
      end

      def add_payment_method(post, payment_method, options)
        card = {}
        card[:number] = payment_method.number
        card[:cvv] = payment_method.verification_value
        card[:expiryMonth] = format(payment_method.month, :two_digits)
        card[:expiryYear] = format(payment_method.year, :two_digits)
        card[:name] = payment_method.name
        post[:card] = card
      end

      def add_reference(post, authorization, options)
        post[:token] = authorization
      end

      ENDPOINT = {
        "tokenize" => "tokens",
        "charge" => "charges",
        "void" => "charges"
      }

      def commit(action, params, authorization=nil)
        response = begin
          parse(ssl_invoke(action, params, authorization))
        rescue ResponseError => e
          parse(e.response.body)
        end

        success = success_from(response)

        Response.new(
          success,
          message_from(success, response),
          response,
          authorization: success ? authorization_from(response) : nil,
          error_code: success ? nil : error_from(response),
          test: test?
        )
      end

      def ssl_invoke(action, params, authorization)
        if action == "void"
          ssl_request(:delete_with_body, url(action, authorization), post_data(params), headers(action))
        else
          ssl_post(url(action, authorization), post_data(params), headers(action))
        end
      end

      def headers(action)
        hfields = {}
        hfields["Public-Merchant-Id"] = @options[:public_merchant_id] if action == "tokenize"
        hfields["Private-Merchant-Id"] = @options[:private_merchant_id] unless action == "tokenize"
        hfields["Content-Type"] = "application/json"
        hfields
      end

      def post_data(params)
        params.to_json
      end

      def url(action, authorization)
        base_url = test? ? test_url : live_url

        if action == "void"
          base_url + ENDPOINT[action] + "/" + authorization
        else
          base_url + ENDPOINT[action]
        end
      end

      def parse(body)
        begin
          JSON.parse(body)
        rescue JSON::ParserError
          message = "Invalid JSON response received from KushkiGateway. Please contact KushkiGateway if you continue to receive this message."
          message += " (The raw response returned by the API was #{body.inspect})"
          {
            "message" => message
          }
        end
      end

      def success_from(response)
        return true if response["token"] || response["ticketNumber"]
      end

      def message_from(succeeded, response)
        if succeeded
          "Succeeded"
        else
          response["message"]
        end
      end

      def authorization_from(response)
        response["token"] || response["ticketNumber"]
      end

      def error_from(response)
        response["code"]
      end
    end
  end
end
