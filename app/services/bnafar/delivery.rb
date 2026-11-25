# Envio dos lotes já reivindicados (BnafarBatch.claim!) ao SI-BNAFAR (módulo
# 27b; contrato §3; Q8, Q14, Q25; R10, R12). Por lote:
#
#   `sending` (a enviar):
#     - fora da janela (Window: o `post` até o fim de R+1; `put` e `delete`
#       até 30 dias do `sent_at` do registro) → `failed` com `window_closed`,
#       sem chamada (o registro fica `pending`: "não enviado");
#     - marca o envio ANTES do HTTP (`sent_at` do lote, dos registros e da
#       remessa, uma vez só: a âncora conservadora da janela de 30 dias, Q25);
#     - POST/PUT (os payloads; em homologação pelo Homologation.apply) ou
#       DELETE (`?codigos=` com os `bnafar_code`);
#     - aceito com protocolo → `processing`; aceito SEM protocolo (2xx de corpo
#       inválido) é transitório, nunca sucesso; recusado (400/422, ex. MSG62)
#       → `failed` e os registros `rejected` com os códigos; credencial
#       recusada → volta `queued` sem contar tentativa, a credencial do
#       ambiente fica `unauthorized` e a cidade pausa (Gate inutilizável, R31);
#       transitório → `queued` com espera de 1, 2, 4… min até BACKOFF_CAP;
#       transitório ou credencial recusada depois do fim da janela → `failed`
#       com `window_closed` (Q31: nunca fica `queued` sob remessa perdida).
#   `processing` (a consultar o protocolo):
#     - situação 1, 2 ou 5 → espera a próxima rodada;
#     - 3 ou 4 → `itensProcessados` e as `inconsistencias` paginadas: registro
#       com `codigoBnafar` → `accepted` (com `rejected_items` e os códigos dos
#       itens recusados: aceite parcial, Q8); MSG15 (duplicado) → `accepted`
#       sem código; o resto → `rejected` com os códigos e
#       `bnafar_record.rejected`. No `delete`, a exclusão se confirma pelo
#       próprio protocolo do lote (`sucesso` e o `codigoBnafar` do registro;
#       nunca o `protocoloExclusao`, que é o do original) → `deleted_at` e
#       `bnafar_record.deleted`. O lote fica `finished`; o `delete` sem
#       nenhuma exclusão confirmada fica `failed` com o primeiro código.
#
# A remessa agrega só as partes `post` (R10): todas acabadas → `finished` (e
# `bnafar_submission.finished`) ou, todas `failed`, `failed`. `put` e
# `delete` nunca a reabrem. A parte em `processing` segue sendo consultada
# depois do fim de R+1 (Q31: Window.close! não perde a remessa dela), e a
# remessa segue esta agregação quando ela acaba.
#
# `delete` que acaba `failed` não volta: `deletion_batch_id` se grava uma vez.
# O registro fica aceito, sem `deleted_at`, e o link do estorno segue
# `deletion`; o saldo na BNAFAR se corrige pela fotografia seguinte, como no
# estorno fora da janela, e o lote `failed` com o código é o rastro.
#
# Em homologação, cada chamada (o jwtauth também, só com o status) acrescenta
# `{ curl, status, body }` à `evidence` do lote, sem token nem senha
# (Bnafar::Evidence). Texto do SI-BNAFAR nunca é gravado: só códigos MSG. Erro
# inesperado num lote não trava os outros: só a classe vai para o relatório.
module Bnafar
  class Delivery
    BUDGET = 4.minutes
    MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    UNAVAILABLE = "bnafar_unavailable".freeze
    INTERNAL = "internal_error".freeze
    NOT_PROCESSED = "not_processed".freeze
    DUPLICATE = "MSG15".freeze
    DONE = %w[3 4].freeze
    MAX_PAGES = 50
    POLL_RETRY = 1.minute
    PAUSE_MESSAGE = "O SI-BNAFAR recusou a credencial durante o envio; o envio está pausado.".freeze

    # Espera depois da n-ésima tentativa: 1, 2, 4… min, até BACKOFF_CAP (Valor 4).
    def self.wait(attempts) = [ 1.minute * (2**(attempts.clamp(1, 16) - 1)), Limits::BACKOFF_CAP ].min

    def initialize(city, environment:, budget: BUDGET, clock: MONOTONIC)
      @city = city
      @environment = environment
      @budget = budget.to_f
      @clock = clock
      @client = Client.for(city, environment: environment)
      @credential = IntegrationCredential.find_by(kind: "bnafar", environment: environment)
      @homologation = environment == "homologation"
      @mapping = Homologation.mapping if @homologation
      @ibge = @homologation ? @mapping["ibge"].to_s : CityProfile.current&.ibge_code.to_s[0, 6]
    end

    # -> :done | :paused
    def run(batches)
      token = batches.first&.last_attempted_at # o token do claim, antes de qualquer transição
      started = @clock.call
      batches.each_with_index do |batch, index|
        if @clock.call - started > @budget
          BnafarBatch.release!(batches[index..].map(&:id), token: token)
          return :done
        end
        next unless deliver(batch, token) == :paused

        BnafarBatch.release!(batches[index..].map(&:id), token: token)
        return :paused
      end
      :done
    end

    def inspect = "#<Bnafar::Delivery #{@environment}>"
    alias_method :to_s, :inspect

    private

    def deliver(batch, token)
      batch.status == "processing" ? poll(batch, token) : submit(batch, token)
    rescue BnafarBatch::LostClaim
      :lost # outra execução é dona do lote: não envia, não mexe
    rescue *Maintenance::CityConnectionErrors::CLASSES
      :skipped # o ensure do job devolve
    rescue StandardError => e
      Rails.error.report(RuntimeError.new("bnafar delivery: #{e.class.name}"), handled: true, severity: :error)
      fallback!(batch, token)
      :error
    end

    # --- envio ---

    def submit(batch, token)
      submission = batch.bnafar_submission
      records = targets(batch)
      return settle!(batch, token, "sending", status: "finished", finished_at: Time.current) if records.empty?

      deadline = deadline(batch, submission, records)
      return close!(batch, token) if deadline.nil? || Time.current > deadline

      body = batch.operation == "delete" ? records.map(&:bnafar_code) : bodies(records)
      mark_sending!(batch, token, records)
      evidence = []
      response = observed(evidence) { call(batch.operation, submission.subject, body) }
      response = transient if response.status == :accepted && response.protocol.nil?
      after_submit(batch, token, records, response, evidence)
    end

    def targets(batch)
      if batch.operation == "delete"
        BnafarRecord.where(deletion_batch_id: batch.id, deleted_at: nil).order(:id).to_a
      else
        batch.records.where(status: "pending").order(:id).to_a
      end
    end

    def deadline(batch, submission, records)
      case batch.operation
      when "post" then Window.retry_until(submission)
      when "put" then records.filter_map { |record| record.replaces_record && Window.correctable_until(record.replaces_record) }.min
      else records.filter_map { |record| Window.correctable_until(record) }.min
      end
    end

    def bodies(records)
      list = records.map { |record| JSON.parse(record.payload) }
      @homologation ? Homologation.apply(list, mapping: @mapping) : list
    end

    def mark_sending!(batch, token, records)
      now = Time.current
      BnafarBatch.transaction(requires_new: true) do
        batch.own!(token, "sending")
        batch.update!(sent_at: now) if batch.sent_at.nil?
        next if batch.operation == "delete" # o `sent_at` do original é a âncora da janela dele

        BnafarRecord.where(id: records.map(&:id), sent_at: nil).update_all(sent_at: now, updated_at: now)
        BnafarSubmission.where(id: batch.bnafar_submission_id, sent_at: nil).update_all(sent_at: now, updated_at: now) if batch.operation == "post"
      end
    end

    def call(operation, subject, body)
      case operation
      when "post" then @client.post_batch(subject: subject, ibge: @ibge, records: body)
      when "put" then @client.put_batch(subject: subject, ibge: @ibge, records: body)
      else @client.delete_batch(subject: subject, ibge: @ibge, codes: body)
      end
    end

    def after_submit(batch, token, records, response, evidence)
      now = Time.current
      attempts = batch.attempts + 1
      limit = deadline(batch, batch.bnafar_submission, records)
      outcome = BnafarBatch.transaction(requires_new: true) do
        batch.own!(token, "sending")
        attrs = evidence_attrs(batch, evidence)
        if %i[transient unauthorized].include?(response.status) && (limit.nil? || now > limit)
          # A janela fechou durante a chamada (Q31): não volta à fila, que sob
          # remessa perdida nunca mais sairia.
          batch.update!(attrs.merge(status: "failed", attempts: attempts, last_error: Window::WINDOW_CLOSED, finished_at: now))
          next(response.status == :unauthorized ? :paused : :sent)
        end
        case response.status
        when :accepted
          batch.update!(attrs.merge(status: "processing", protocol: response.protocol, attempts: attempts, last_error: nil, next_attempt_at: now))
        when :rejected
          batch.update!(attrs.merge(status: "failed", attempts: attempts, last_error: response.error_codes.first || "rejected", finished_at: now))
          reject!(records, response.error_codes) unless batch.operation == "delete"
        when :unauthorized
          batch.update!(attrs.merge(status: "queued")) # não chegou a ser tentado: sem tentativa
          next :paused
        else
          batch.update!(attrs.merge(status: "queued", attempts: attempts, last_error: UNAVAILABLE, next_attempt_at: now + self.class.wait(attempts)))
        end
        :sent
      end
      refresh!(batch.bnafar_submission_id, now) if batch.operation == "post"
      outcome == :paused ? pause! : outcome
    end

    def close!(batch, token)
      settle!(batch, token, "sending", status: "failed", last_error: Window::WINDOW_CLOSED, finished_at: Time.current)
    end

    def settle!(batch, token, owned_status, **attrs)
      BnafarBatch.transaction(requires_new: true) do
        batch.own!(token, owned_status)
        batch.update!(attrs)
      end
      refresh!(batch.bnafar_submission_id, Time.current) if batch.operation == "post"
      :settled
    end

    # --- consulta do protocolo ---

    def poll(batch, token)
      batch.own!(token, "processing")
      evidence = []
      detail = observed(evidence) { @client.detail(ibge: @ibge, protocol: batch.protocol) }
      return poll_later(batch, token, detail, evidence) unless detail.status == :accepted
      return poll_later(batch, token, detail, evidence, wait: 0) unless DONE.include?(detail.situation.to_s)

      issues = {}
      if detail.situation.to_s == "4" || detail.items.any? { |item| !item[:success] }
        page = 0
        pages = 1
        while page < pages && page < MAX_PAGES
          found = observed(evidence) { @client.inconsistencies(ibge: @ibge, protocol: batch.protocol, page: page) }
          return poll_later(batch, token, found, evidence) unless found.status == :accepted

          found.items.each do |entry|
            issue = (issues[entry[:origin_code]] ||= { codes: [], rejected_items: 0 })
            issue[:codes] |= Array(entry[:codes])
            issue[:rejected_items] += entry[:rejected_items].to_i
          end
          pages = found.pages.to_i
          page += 1
        end
      end
      conclude!(batch, token, detail, issues, evidence)
    end

    # Ainda processando (wait: 0), transitório, recusado ou credencial recusada.
    def poll_later(batch, token, response, evidence, wait: POLL_RETRY)
      now = Time.current
      BnafarBatch.transaction(requires_new: true) do
        batch.own!(token, "processing")
        attrs = evidence_attrs(batch, evidence)
        if response.status == :rejected # protocolo desconhecido (MSG19) e afins
          batch.update!(attrs.merge(status: "failed", last_error: response.error_codes.first || "rejected", finished_at: now))
          reject!(batch.records.where(status: "pending").to_a, response.error_codes) unless batch.operation == "delete"
        else
          batch.update!(attrs.merge(next_attempt_at: now + (response.status == :accepted ? wait : POLL_RETRY)))
        end
      end
      refresh!(batch.bnafar_submission_id, now) if batch.operation == "post" && response.status == :rejected
      response.status == :unauthorized ? pause! : :polled
    end

    def conclude!(batch, token, detail, issues, evidence)
      now = Time.current
      BnafarBatch.transaction(requires_new: true) do
        batch.own!(token, "processing")
        attrs = evidence_attrs(batch, evidence).merge(finished_at: now)
        if batch.operation == "delete"
          deleted = confirm_deletions!(batch, detail, now)
          codes = issues.values.flat_map { |issue| issue[:codes] }.uniq
          batch.update!(deleted ? attrs.merge(status: "finished", last_error: nil) : attrs.merge(status: "failed", last_error: codes.first || NOT_PROCESSED))
        else
          settle_records!(batch, detail, issues, now)
          batch.update!(attrs.merge(status: "finished", last_error: nil))
        end
      end
      refresh!(batch.bnafar_submission_id, now) if batch.operation == "post"
      :concluded
    end

    def settle_records!(batch, detail, issues, now)
      by_origin = detail.items.index_by { |item| item[:origin_code] }
      batch.records.where(status: "pending").order(:id).each do |record|
        item = by_origin[record.origin_code]
        issue = issues[record.origin_code] || { codes: [], rejected_items: 0 }
        code = positive_integer(item && item[:bnafar_code])
        if code || item&.dig(:success)
          accept!(record, code, issue[:rejected_items], issue[:codes], now)
        elsif issue[:codes].include?(DUPLICATE)
          accept!(record, nil, issue[:rejected_items], issue[:codes] - [ DUPLICATE ], now)
        else
          reject!([ record ], issue[:codes].presence || (item ? [] : [ NOT_PROCESSED ]))
        end
      end
    end

    def accept!(record, code, rejected_items, codes, now)
      record.update!(status: "accepted", accepted_at: now, bnafar_code: code, rejected_items: rejected_items, error_codes: codes)
    end

    def reject!(records, codes)
      records.each do |record|
        record.update!(status: "rejected", error_codes: Array(codes))
        DomainEvents.publish("bnafar_record.rejected", bnafar_record_id: record.id, bnafar_submission_id: record.bnafar_submission_id)
      end
    end

    # A exclusão se confirma pelo protocolo do próprio lote `delete`. -> Boolean (alguma?)
    def confirm_deletions!(batch, detail, now)
      confirmed = detail.items.select { |item| item[:success] }.filter_map { |item| positive_integer(item[:bnafar_code]) }.to_set
      records = BnafarRecord.where(deletion_batch_id: batch.id, deleted_at: nil).order(:id).select { |record| confirmed.include?(record.bnafar_code) }
      records.each do |record|
        record.update!(deleted_at: now)
        DomainEvents.publish("bnafar_record.deleted", bnafar_record_id: record.id, bnafar_batch_id: batch.id)
      end
      records.any?
    end

    # --- remessa (R10: só as partes `post`) ---

    def refresh!(submission_id, now)
      BnafarSubmission.transaction(requires_new: true) do
        submission = BnafarSubmission.lock.find(submission_id)
        next if %w[building lost].include?(submission.status)

        posts = submission.batches.where(operation: "post").order(:created_at, :id).pluck(:status, :attempts, :last_error)
        next if posts.empty?

        target = aggregate(posts.map(&:first))
        attrs = { attempts: [ submission.attempts, posts.sum { |row| row[1] } ].max, last_error: posts.filter_map(&:last).last }
        closed = %w[finished failed].include?(submission.status)
        if target != submission.status && (!closed || target == "queued")
          attrs[:status] = target
          attrs[:finished_at] = now if target == "finished"
        end
        submission.update!(attrs)
        DomainEvents.publish("bnafar_submission.finished", bnafar_submission_id: submission.id) if attrs[:status] == "finished"
      end
    end

    def aggregate(statuses)
      if statuses.all? { |status| %w[finished failed].include?(status) }
        statuses.include?("finished") ? "finished" : "failed"
      elsif statuses.include?("processing") then "processing"
      elsif statuses.include?("sending") then "sending"
      else "queued"
      end
    end

    # --- apoio ---

    def pause!
      if @credential
        IntegrationCredential.where(id: @credential.id, set_at: @credential.set_at)
                             .update_all(last_check_status: "unauthorized", last_check_at: Time.current,
                                         last_check_message: PAUSE_MESSAGE, updated_at: Time.current)
      end
      :paused
    end

    # Erro inesperado: o lote volta com espera e o código (nunca a mensagem).
    def fallback!(batch, token)
      now = Time.current
      BnafarBatch.where(id: batch.id, status: "sending", last_attempted_at: token)
                 .update_all([ "status = 'queued', attempts = attempts + 1, last_error = ?, next_attempt_at = ?, updated_at = ?",
                               INTERNAL, now + self.class.wait(batch.attempts + 1), now ])
      BnafarBatch.where(id: batch.id, status: "processing", last_attempted_at: token).update_all(next_attempt_at: now + POLL_RETRY, updated_at: now)
    rescue StandardError
      nil
    end

    # Em homologação, as chamadas do bloco entram em `evidence`.
    def observed(evidence)
      return yield unless @homologation

      @client.observer = ->(**call) { evidence << evidence_entry(call) }
      yield
    ensure
      @client.observer = nil if @homologation
    end

    def evidence_entry(call)
      if call[:auth]
        { "curl" => Evidence.login(url: call[:url], environment: @environment), "status" => call[:status], "body" => nil }
      else
        { "curl" => Evidence.curl(method: call[:method], url: call[:url], body: call[:body], environment: @environment),
          "status" => call[:status], "body" => Evidence.response(call[:response], environment: @environment) }
      end
    end

    def evidence_attrs(batch, entries)
      return {} unless @homologation && entries.any?

      { evidence: Array(batch.evidence) + entries }
    end

    def transient
      Client::Response.new(status: :transient, protocol: nil, situation: nil, items: [], error_codes: [], pages: nil)
    end

    def positive_integer(value)
      number = Integer(value.to_s, 10)
      number.positive? ? number : nil
    rescue ArgumentError, TypeError
      nil
    end
  end
end
