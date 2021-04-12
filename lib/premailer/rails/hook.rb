class Premailer
  module Rails
    class Hook
      attr_reader :message

      class << self
        def perform(message)
          new(message).perform
          message
        end

        alias_method :delivering_email, :perform
        alias_method :previewing_email, :perform
      end

      def initialize(message)
        @message = message
      end

      def perform
        if skip_premailer_header_present?
          remove_skip_premailer_header
        else
          replace_html_part(generate_html_part_replacement) if message_contains_html?
          replace_amp_part(generate_amp_part_replacement) if message_contains_amp?
        end
      end

      private

      def skip_premailer_header_present?
        message.header[:skip_premailer]
      end

      def remove_skip_premailer_header
        message.header[:skip_premailer] = nil
      end

      def message_contains_html?
        html_part.present?
      end

      def message_contains_amp?
        amp_part.present?
      end

      # Returns true if the message itself has a content type of text/html, thus
      # it does not contain other parts such as alternatives and attachments.
      def pure_html_message?
        message.content_type && message.content_type.include?('text/html')
      end

      def pure_amp_message?
        message.content_type && message.content_type.include?('text/x-amp-html')
      end

      def generate_html_part_replacement
        if generate_text_part?
          generate_alternative_part
        else
          generate_html_part
        end
      end

      def generate_amp_part_replacement
        if generate_text_part?
          generate_alternative_part
        else
          generate_amp_part
        end
      end

      def generate_text_part?
        Rails.config[:generate_text_part] && !message.text_part
      end

      def generate_alternative_part
        part = Mail::Part.new(content_type: 'multipart/alternative')
        part.add_part(generate_text_part)
        part.add_part(generate_html_part) if message_contains_html?
        part.add_part(generate_amp_part) if message_contains_amp?

        part
      end

      def generate_html_part
        # Make sure that the text part is generated first. Otherwise the text
        # can end up containing CSS rules.
        generate_text_part if generate_text_part?

        inlined = CustomizedPremailer.new(html_part.decoded).to_inline_css
        Mail::Part.new do
          content_type "text/html; charset=#{inlined.encoding}"
          body inlined
        end
      end

      def generate_amp_part
        # Make sure that the text part is generated first. Otherwise the text
        # can end up containing CSS rules.
        generate_text_part if generate_text_part?

        inlined = CustomizedPremailer.new(amp_part.decoded).
          to_inline_css.
          gsub("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">", '').
          gsub('!important', '').
          gsub("<style>", "<style amp-custom>")

        Mail::Part.new do
          content_type "text/x-amp-html; charset=#{inlined.encoding}"
          body inlined
        end
      end

      def generate_text_part
        decoded_html_part = CustomizedPremailer.new(html_part.decoded)
        @text_part ||= begin
                         text = decoded_html_part.to_plain_text
                         Mail::Part.new do
                           content_type "text/plain; charset=#{text.encoding}"
                           body text
                         end
                       end
      end

      def html_part
        if pure_html_message?
          message
        else
          message.html_part
        end
      end

      def amp_part
        if pure_amp_message?
          message
        else
          message.parts.detect{ |p| p.content_type.include?('text/x-amp-html') }
        end
      end

      def replace_html_part(new_part)
        if pure_html_message?
          replace_in_pure_part_message(new_part, 'text/html')
        else
          replace_part_in_list(message.parts, html_part, new_part)
        end
      end

      def replace_amp_part(new_part)
        if pure_amp_message?
          replace_in_pure_part_message(new_part, 'text/x-amp-html')
        else
          replace_part_in_list(message.parts, amp_part, new_part)
        end
      end

      # If the new part is a pure text/html part, the body and its content type
      # are used for the message. If the new part is
      def replace_in_pure_part_message(new_part, content_type)
        if new_part.content_type.include?(content_type)
          message.body = new_part.decoded
          message.content_type = new_part.content_type
        else
          message.body = nil
          message.content_type = new_part.content_type
          new_part.parts.each do |part|
            message.add_part(part)
          end
        end
      end

      def replace_part_in_list(parts_list, old_part, new_part)
        if (index = parts_list.index(old_part))
          parts_list[index] = new_part
        else
          parts_list.any? do |part|
            if part.respond_to?(:parts)
              replace_part_in_list(part.parts, old_part, new_part)
            end
          end
        end
      end
    end
  end
end
