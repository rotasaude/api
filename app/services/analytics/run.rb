module Analytics
  # Uma consolidação (spec §4.1): trava por cidade, registro em
  # analytics_runs, fatos da janela refeitos numa transação só, publicação
  # depois do commit e purgas. Devolve o AnalyticsRun, ou nil quando outra
  # consolidação da mesma cidade está em curso (sai sem gravar nada).
  #
  # Falha de consolidação vira run failed com os fatos anteriores intactos, não
  # exceção: quem chama decide (o job levanta; o rebuild para).
  class Run
    # Uma chave por banco: cada cidade tem o seu, então a trava já é por cidade.
    LOCK_KEY = "analytics_consolidation"
    WINDOW_DAYS = 30
    FACT_RETENTION = 5.years
    RUN_RETENTION = 90.days
    ERROR_LIMIT = 500

    class Failed < StandardError; end

    def self.scheduled_window(today = Time.zone.today) = [ today - WINDOW_DAYS, today - 1 ]

    def self.call(kind:, from:, to:)
      raise ArgumentError, "janela invertida: #{from}..#{to}" if from > to
      raise ArgumentError, "o dia corrente nunca é consolidado (to=#{to})" if to >= Time.zone.today
      return nil unless try_lock

      begin
        new(kind: kind, from: from, to: to).call
      ensure
        unlock
      end
    end

    # Trava de SESSÃO (não de transação): cobre consolidação, publicação e
    # purga, que rodam em transações diferentes. Liberada no ensure.
    def self.try_lock
      ApplicationRecord.connection.select_value("SELECT pg_try_advisory_lock(hashtext('#{LOCK_KEY}'))")
    end

    def self.unlock
      ApplicationRecord.connection.select_value("SELECT pg_advisory_unlock(hashtext('#{LOCK_KEY}'))")
    end

    # Classe e primeira linha da mensagem: a linha DETAIL do PostgreSQL pode
    # trazer valores da linha que falhou.
    def self.describe(error)
      "#{error.class}: #{error.message.to_s.lines.first.to_s.strip}".truncate(ERROR_LIMIT)
    end

    def initialize(kind:, from:, to:)
      @kind = kind
      @from = from
      @to = to
    end

    def call
      run = AnalyticsRun.create!(kind: @kind, status: "running", window_from: @from, window_to: @to,
                                 started_at: Time.current)
      begin
        # requires_new: transação de verdade em produção, savepoint dentro de
        # outra (specs) — nos dois casos a falha desfaz só a janela.
        ApplicationRecord.transaction(requires_new: true) do
          Consolidate.call(from: @from, to: @to, at: run.started_at)
        end
      rescue StandardError => e
        run.update!(status: "failed", finished_at: Time.current, error: self.class.describe(e))
        return run
      end

      run.update!(status: "succeeded", finished_at: Time.current)
      publish(run)
      purge
      run
    end

    private

    # A próxima execução republica a própria janela (spec §4.1).
    def publish(run)
      Publish.call(from: run.window_from, to: run.window_to, at: Time.current)
      run.update!(published_at: Time.current)
    rescue StandardError => e
      run.update!(error: "publish: #{self.class.describe(e)}".truncate(ERROR_LIMIT))
    end

    # Guarda o último succeeded mesmo velho (desvio 8 do plano): sem ele,
    # as_of voltaria nulo com fatos no banco.
    def purge
      AnalyticsDailyFact.where(day: ...(Time.zone.today - FACT_RETENTION)).delete_all
      keep = AnalyticsRun.where(status: "succeeded").order(finished_at: :desc).limit(1).pluck(:id)
      AnalyticsRun.where(started_at: ...RUN_RETENTION.ago).where.not(id: keep).delete_all
    end
  end
end
