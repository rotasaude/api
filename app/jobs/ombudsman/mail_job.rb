# Envio dos e-mails da ouvidoria (ADR 0051; contrato §4). SMTP aqui, fora do
# consumidor de evento (ADR-0005).
#
#   kind "anonymous_cap":   ref = data ISO do dia local do bloqueio; lê só a
#                           contagem das denúncias anônimas do canal web do dia.
#   kind "daily_summary":   ref = data ISO do dia; contagens de manifestações
#                           abertas vermelhas e amarelas (sem as pausadas) ao
#                           ouvidor e ao técnico (Task 17).
#   kind "responder_summary": ref = data ISO do dia; a cada respondente, as
#                           contagens dos encaminhamentos pendentes dele.
#
# Dedup no padrão do Surveillance::MailJob: ProcessedEvent (consumer
# "ombudsman_mail", event_id "<kind>:<ref>") depois de saber que há o que
# dizer (contagem zero não consome o dia) e ANTES da entrega; a transação do
# with_city o desfaz se a entrega levantar, e o retry reentrega. Um e-mail por
# destinatário (ninguém vê o endereço do outro); recusa permanente do servidor
# pula o endereço e é contada. Não relê o interruptor: o bloqueio só acontece
# pela rota já guardada pelo portão, e o interruptor não se lê dentro da
# transação da cidade. O e-mail leva só a data e a contagem — nunca protocolo,
# texto, unidade nem id; o log, só kind e contagens.
module Ombudsman
  class MailJob < ApplicationJob
    include CityScopedJob
    queue_as :urgent

    # Mesmos erros transitórios do Surveillance::MailJob.
    retry_on Net::SMTPServerBusy, Net::SMTPUnknownError, Net::OpenTimeout, Net::ReadTimeout,
             Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Timeout::Error,
             EOFError, IOError, OpenSSL::SSL::SSLError,
             attempts: 5, wait: :polynomially_longer

    CONSUMER = "ombudsman_mail".freeze
    KINDS = %w[anonymous_cap daily_summary responder_summary].freeze

    def perform(city_slug:, kind:, ref:)
      raise ArgumentError, "unknown kind" unless KINDS.include?(kind)

      with_city(city_slug) do
        # Primeiro o que dizer, depois o dedup: a rodada sem nada a dizer não
        # consome o dia, e a seguinte com contagem ainda envia.
        plan = send("#{kind}_plan", ref)
        next if plan.nil?
        next if duplicate?("#{kind}:#{ref}")

        recipients, mails = plan
        delivered, failed = deliver_each(recipients, mails)
        level = failed.positive? ? :warn : :info
        Rails.logger.public_send(level, "[#{self.class.name}] kind=#{kind} recipients=#{recipients.size} delivered=#{delivered} failed=#{failed}")
      end
    end

    private

    def deliver_each(recipients, mails)
      failed = 0
      recipients.each do |to|
        mails.call(to).deliver_now
      rescue Net::SMTPFatalError, Net::SMTPSyntaxError
        failed += 1
      end
      [ recipients.size - failed, failed ]
    end

    # requires_new (SAVEPOINT): ver DispatchMunicipalityAlertJob.
    def duplicate?(event_id)
      ApplicationRecord.transaction(requires_new: true) do
        ProcessedEvent.create!(consumer: CONSUMER, event_id: event_id, processed_at: Time.current)
      end
      false
    rescue ActiveRecord::RecordNotUnique
      Rails.logger.info("[#{self.class.name}] skip duplicate")
      true
    end

    # Cada *_plan devolve nil (nada a dizer) ou [destinatários, ->(to) { mail }].
    def anonymous_cap_plan(date_string)
      date = Date.iso8601(date_string)
      count = OmbudsmanManifestation.where(channel: "web", identification_mode: "anonymous",
                                           received_at: date.in_time_zone.all_day).count
      return nil if count.zero?

      [ Recipients.emails(%w[ombudsman]), ->(to) { OmbudsmanMailer.anonymous_cap(to: to, date: date, count: count) } ]
    end

    def daily_summary_plan(date_string)
      date = Date.iso8601(date_string)
      settings = OmbudsmanSetting.current
      red = OmbudsmanManifestation.where("#{Deadlines.color_sql(settings, today: date)} = 'red'").count
      yellow = OmbudsmanManifestation.where("#{Deadlines.color_sql(settings, today: date)} = 'yellow'").count
      return nil if red.zero? && yellow.zero?

      [ Recipients.emails(Access::STAFF_ROLES),
        ->(to) { OmbudsmanMailer.daily_summary(to: to, date: date, red: red, yellow: yellow) } ]
    end

    def responder_summary_plan(date_string)
      date = Date.iso8601(date_string)
      warning = OmbudsmanSetting.current.warning_days
      counts = responder_counts(date, warning)
      return nil if counts.empty?

      [ counts.keys.sort, ->(to) { OmbudsmanMailer.responder_summary(to: to, date: date, **counts.fetch(to)) } ]
    end

    # { e-mail => { pending:, red:, yellow: } } dos respondentes com encaminhamento
    # pendente nos destinos deles (Access.destinations; papel e linha ativos).
    def responder_counts(date, warning)
      users = User.where(deactivated_at: nil, id: Access.responder_rows.select(:user_id)).order(:email_address)
      users.each_with_object({}) do |user, counts|
        destinations = Access.destinations(user)
        pending = OmbudsmanForwarding.where(state: "pending")
                                     .where(department_id: destinations[:department_ids]).or(
                                       OmbudsmanForwarding.where(state: "pending").where(health_unit_id: destinations[:health_unit_ids])
                                     )
        total = pending.count
        next if total.zero?

        red = pending.where("due_on < ?", date).count
        yellow = pending.where("due_on >= ? AND due_on <= ?", date, date + warning).count
        counts[user.email_address] = { pending: total, red: red, yellow: yellow }
      end
    end
  end
end
