require 'net/pop'
require_dependency 'email/receiver'
require_dependency 'email/sender'
require_dependency 'email/message_builder'

module Jobs
  class PollMailbox < Jobs::Scheduled
    every SiteSetting.pop3_polling_period_mins.minutes
    sidekiq_options retry: false

    include Email::BuildEmailHelper

    def execute(args)
      @args = args
      poll_pop3 if should_poll?
    end

    def should_poll?
      return false if Rails.env.development? && ENV["POLL_MAILBOX"].nil?
      SiteSetting.pop3_polling_enabled?
    end

    def process_popmail(popmail)
      begin
        mail_string = popmail.pop
        receiver = Email::Receiver.new(mail_string)
        receiver.process!
      rescue Email::Receiver::BouncedEmailError => e
        log_email_process_failure(mail_string, e)

        set_incoming_email_rejection_message(
          receiver.incoming_email,
          I18n.t("emails.incoming.errors.bounced_email_error")
        )
      rescue Email::Receiver::AutoGeneratedEmailReplyError => e
        log_email_process_failure(mail_string, e)

        set_incoming_email_rejection_message(
          receiver.incoming_email,
          I18n.t("emails.incoming.errors.auto_generated_email_reply")
        )
      rescue => e
        rejection_message = handle_failure(mail_string, e)
        if rejection_message.present? && receiver && (incoming_email = receiver.incoming_email)
          set_incoming_email_rejection_message(incoming_email, rejection_message.body.to_s)
        end
      end
    end

    def handle_failure(mail_string, e)
      log_email_process_failure(mail_string, e)

      message_template = case e
        when Email::Receiver::EmptyEmailError             then :email_reject_empty
        when Email::Receiver::NoBodyDetectedError         then :email_reject_empty
        when Email::Receiver::UserNotFoundError           then :email_reject_user_not_found
        when Email::Receiver::ScreenedEmailError          then :email_reject_screened_email
        when Email::Receiver::AutoGeneratedEmailError     then :email_reject_auto_generated
        when Email::Receiver::InactiveUserError           then :email_reject_inactive_user
        when Email::Receiver::BlockedUserError            then :email_reject_blocked_user
        when Email::Receiver::BadDestinationAddress       then :email_reject_bad_destination_address
        when Email::Receiver::StrangersNotAllowedError    then :email_reject_strangers_not_allowed
        when Email::Receiver::InsufficientTrustLevelError then :email_reject_insufficient_trust_level
        when Email::Receiver::ReplyUserNotMatchingError   then :email_reject_reply_user_not_matching
        when Email::Receiver::TopicNotFoundError          then :email_reject_topic_not_found
        when Email::Receiver::TopicClosedError            then :email_reject_topic_closed
        when Email::Receiver::InvalidPost                 then :email_reject_invalid_post
        when ActiveRecord::Rollback                       then :email_reject_invalid_post
        when Email::Receiver::InvalidPostAction           then :email_reject_invalid_post_action
        when Discourse::InvalidAccess                     then :email_reject_invalid_access
        when RateLimiter::LimitExceeded                   then :email_reject_rate_limit_specified
      end

      template_args = {}
      client_message = nil

      # there might be more information available in the exception
      if message_template == :email_reject_invalid_post && e.message.size > 6
        message_template = :email_reject_invalid_post_specified
        template_args[:post_error] = e.message
      end

      if message_template == :email_reject_rate_limit_specified
        template_args[:rate_limit_description] = e.description
      end

      if message_template == :email_reject_auto_generated
        template_args[:mark_as_reply_to_auto_generated] = true
      end

      if message_template
        # inform the user about the rejection
        message = Mail::Message.new(mail_string)
        template_args[:former_title] = message.subject
        template_args[:destination] = message.to
        template_args[:site_name] = SiteSetting.title

        client_message = RejectionMailer.send_rejection(message_template, message.from, template_args)
        Email::Sender.new(client_message, message_template).send
      else
        mark_as_errored!
        Discourse.handle_job_exception(e, error_context(@args, "Unrecognized error type when processing incoming email", mail: mail_string))
      end

      client_message
    end

    POLL_MAILBOX_TIMEOUT_ERROR_KEY = "poll_mailbox_timeout_error_key".freeze

    def poll_pop3
      pop3 = Net::POP3.new(SiteSetting.pop3_polling_host, SiteSetting.pop3_polling_port)
      pop3.enable_ssl if SiteSetting.pop3_polling_ssl

      pop3.start(SiteSetting.pop3_polling_username, SiteSetting.pop3_polling_password) do |pop|
        pop.delete_all do |p|
          process_popmail(p)
        end
      end
    rescue Net::OpenTimeout => e
      count = $redis.incr(POLL_MAILBOX_TIMEOUT_ERROR_KEY).to_i

      $redis.expire(
        POLL_MAILBOX_TIMEOUT_ERROR_KEY,
        SiteSetting.pop3_polling_period_mins.minutes * 3
      ) if count == 1

      if count > 3
        $redis.del(POLL_MAILBOX_TIMEOUT_ERROR_KEY)
        mark_as_errored!
        add_admin_dashboard_problem_message('dashboard.poll_pop3_timeout')
        Discourse.handle_job_exception(e, error_context(@args, "Connecting to '#{SiteSetting.pop3_polling_host}' for polling emails."))
      end
    rescue Net::POPAuthenticationError => e
      mark_as_errored!
      add_admin_dashboard_problem_message('dashboard.poll_pop3_auth_error')
      Discourse.handle_job_exception(e, error_context(@args, "Signing in to poll incoming emails."))
    end

    POLL_MAILBOX_ERRORS_KEY ||= "poll_mailbox_errors".freeze

    def self.errors_in_past_24_hours
      $redis.zremrangebyscore(POLL_MAILBOX_ERRORS_KEY, 0, 24.hours.ago.to_i)
      $redis.zcard(POLL_MAILBOX_ERRORS_KEY).to_i
    end

    def mark_as_errored!
      now = Time.now.to_i
      $redis.zadd(POLL_MAILBOX_ERRORS_KEY, now, now.to_s)
    end

    private

    def set_incoming_email_rejection_message(incoming_email, message)
      incoming_email.update_attributes!(rejection_message: message)
    end

    def log_email_process_failure(mail_string, exception)
      if SiteSetting.log_mail_processing_failures
        Rails.logger.warn("Email can not be processed: #{exception}\n\n#{mail_string}")
      end
    end

    def add_admin_dashboard_problem_message(i18n_key)
      AdminDashboardData.add_problem_message(
        i18n_key,
        SiteSetting.pop3_polling_period_mins.minutes + 5.minutes
      )
    end

  end
end