# Montagem das remessas de R (módulo 27b; contrato §3; Valores 4, 6 e 7; Q8,
# Q14, Q25; R10, R12; Review Focus 2 e 4). Por assunto, uma remessa por (R,
# assunto, ambiente) — o índice único — criada `building` ou retomada:
#
#   - posição: um registro por (CNES, item, parte de ITEMS_PER_RECORD lotes),
#     da fotografia de R (Snapshot, corte no início de R+1);
#   - saída: um registro por movimento criado em R (Exits), com o link `exit`;
#   - estorno de uso direto (Exits::Reversal, Q14) do registro ACEITO, com
#     `bnafar_code` e ainda na janela (Window.correctable?, do `sent_at`, Q25)
#     → um lote `delete` na remessa do original (R10: tem ciclo próprio e não a
#     reabre), `deletion_batch_id` no original e o link `deletion`. Fora disso
#     (aceito há mais de 30 dias, aceito sem código — MSG15 —, ainda pendente
#     ou recusado) → o link `late_reversal`, sem chamada: a fotografia seguinte
#     já corrige o saldo. O estorno cujo original está NESTA remessa (só na
#     retomada: a compensação parcial ligou o original numa parte anterior)
#     não vira nada, como na primeira passada;
#   - a linha com pendência fica fora e o resto vai (Pendencies.clean).
#
# Retomável por partes. Cada parte é uma transação curta com a remessa travada
# (FOR UPDATE): relê o que falta sobre o que já foi gravado e grava UM lote
# `post` (até RECORDS_PER_BATCH registros; o grupo (CNES, item) nunca se
# parte entre lotes). Dois jobs juntos se revezam parte a parte; o que morre no
# meio deixa as partes já gravadas, e a próxima execução segue de onde parou.
# O `origin_code` é um UUID v5 da remessa e do registro: o mesmo em toda
# retomada (o índice único dele é a segunda trava). Sem nada a enviar, a
# remessa nasce `finished`; com registro, `queued` e `bnafar_submission.queued`,
# e o primeiro dia com registro grava `bnafar_settings.started_on`.
#
# `domains` chega lido fora da transação (Gate.domains_through). "Hoje" e os
# cortes são do fuso corrente (o da cidade em CityConnection.with).
module Bnafar
  module Build
    NAMESPACE = "5d0b27b0-bafa-4c11-9e27-0b5e11d00b27".freeze

    module_function

    def call(reference_on:, environment:, domains:, now: Time.current)
      raise ArgumentError, "ambiente desconhecido" unless Catalog::ENVIRONMENTS.include?(environment)

      submissions = Catalog::SUBJECTS.map do |subject|
        submission = open!(reference_on, subject, environment, now)
        build!(submission, Array(domains), now) if submission.status == "building"
        submission.reload
      end
      Result.ok(submissions: submissions)
    end

    def open!(reference_on, subject, environment, now)
      BnafarSubmission.insert_all([ { reference_on: reference_on, subject: subject, environment: environment, status: "building",
                                      building_started_at: now, created_at: now, updated_at: now } ],
                                  unique_by: %i[reference_on subject environment])
      BnafarSubmission.find_by!(reference_on: reference_on, subject: subject, environment: environment)
    end

    def build!(submission, domains, now)
      loop do
        more = BnafarSubmission.transaction(requires_new: true) do
          locked = BnafarSubmission.lock.find(submission.id)
          locked.status == "building" && step!(locked, domains, now)
        end
        break unless more
      end
    end

    # Uma parte. -> true (há mais) | false (a remessa fechou).
    def step!(submission, domains, now)
      if submission.subject == "exit"
        found = exits_of(submission, domains)
        reversals = found[:reversals].reject { |reversal| reversal.original_link.bnafar_record.bnafar_submission_id == submission.id }
        return reverse!(reversals, now) if reversals.any?

        units = exit_units(submission, Pendencies.clean(found[:exits]))
      else
        units = position_units(submission, domains)
      end
      return finish!(submission, now) if units.empty?

      post!(submission, take(units), now)
      true
    end

    # [[registro]] por grupo (CNES, item) ainda não gravado; o registro leva o
    # payload num bloco (montado só para o que entra no lote).
    def position_units(submission, domains)
      reference_on = submission.reference_on
      rows = Pendencies.clean(Snapshot.call(reference_on: reference_on, domains: domains, cutoff: cut(reference_on + 1)))
      groups = Snapshot.groups(rows)
      done = BnafarRecord.where(origin_code: groups.keys.map { |cnes, item_key| origin(submission, cnes, item_key, 0) }).pluck(:origin_code).to_set
      groups.filter_map do |(cnes, item_key), group|
        next if done.include?(origin(submission, cnes, item_key, 0))

        group.group_by { |row| row.lot.id }.values.each_slice(Limits::ITEMS_PER_RECORD).each_with_index.map do |lots, part|
          part_rows = lots.flatten
          code = origin(submission, cnes, item_key, part)
          { origin_code: code, stock_location_id: part_rows.first.location.id, item_key: item_key, stock_external_exit_id: nil, movement: nil,
            payload: -> { Payload.position(cnes: cnes, type: part_rows.first.type, reference_on: reference_on, origin_code: code, rows: part_rows) } }
        end
      end
    end

    def exit_units(submission, rows)
      items = Items.new(rows.map(&:lot))
      rows.map do |row|
        movement = row.movement
        code = origin(submission, movement.id)
        [ { origin_code: code, stock_location_id: movement.stock_location_id, item_key: items.key(row.lot),
            stock_external_exit_id: movement.stock_external_exit_id, movement: movement, payload: -> { Payload.exit(row, origin_code: code) } } ]
      end
    end

    # Grupos inteiros até RECORDS_PER_BATCH registros (pelo menos um grupo).
    def take(units)
      taken = []
      units.each do |unit|
        break if taken.any? && taken.size + unit.size > Limits::RECORDS_PER_BATCH

        taken.concat(unit)
      end
      taken
    end

    def post!(submission, records, now)
      batch = BnafarBatch.create!(bnafar_submission: submission, operation: "post", status: "queued", next_attempt_at: now)
      records.each do |attrs|
        record = BnafarRecord.create!(bnafar_submission: submission, bnafar_batch: batch, origin_code: attrs[:origin_code], subject: submission.subject,
                                      stock_location_id: attrs[:stock_location_id], item_key: attrs[:item_key],
                                      stock_external_exit_id: attrs[:stock_external_exit_id], payload: JSON.generate(attrs[:payload].call))
        BnafarMovementLink.create!(stock_movement: attrs[:movement], bnafar_record: record, kind: "exit") if attrs[:movement]
      end
    end

    # Q14: `deletion` (lote `delete` na remessa do original) ou `late_reversal`. -> true
    def reverse!(reversals, now)
      deletions = {}
      reversals.each do |reversal|
        record = BnafarRecord.lock.find(reversal.original_link.bnafar_record_id)
        kind = if record.deletion_batch_id || record.deleted_at || deletions.fetch(record.bnafar_submission_id, []).include?(record)
                 "deletion"
               elsif deletable?(record, now)
                 (deletions[record.bnafar_submission_id] ||= []) << record
                 "deletion"
               else
                 "late_reversal"
               end
        BnafarMovementLink.create!(stock_movement: reversal.movement, bnafar_record: record, kind: kind)
      end
      deletions.each do |submission_id, records|
        submission = BnafarSubmission.find(submission_id)
        records.each_slice(Limits::RECORDS_PER_BATCH) do |slice|
          batch = BnafarBatch.create!(bnafar_submission: submission, operation: "delete", status: "queued", next_attempt_at: now)
          slice.each { |record| record.update!(deletion_batch_id: batch.id) }
        end
      end
      true
    end

    def deletable?(record, now) = record.status == "accepted" && record.bnafar_code.present? && Window.correctable?(record, now: now)

    def finish!(submission, now)
      if submission.records.exists?
        submission.update!(status: "queued")
        setting = BnafarSetting.current
        setting.update!(started_on: submission.reference_on) if setting.started_on.nil?
        DomainEvents.publish("bnafar_submission.queued", bnafar_submission_id: submission.id)
      else
        submission.update!(status: "finished", finished_at: now)
      end
      false
    end

    def exits_of(submission, domains)
      day = submission.reference_on
      Exits.call(day: day, domains: domains, from: cut(day), to: cut(day + 1))
    end

    def cut(day) = day.in_time_zone.beginning_of_day
    def origin(submission, *parts) = Digest::UUID.uuid_v5(NAMESPACE, [ submission.id, *parts ].join(":"))

    private_class_method :open!, :build!, :step!, :position_units, :exit_units, :take, :post!, :reverse!, :deletable?, :finish!,
                         :exits_of, :cut, :origin
  end
end
