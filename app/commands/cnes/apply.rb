# app/commands/cnes/apply.rb
# Confirma propostas do CNES (ADR 0028; spec 2026-10-05 §5; contratos §5.2).
# Sob trava da cidade (pg_advisory_xact_lock), RECALCULA as propostas e aplica
# só as que ainda existem com o mesmo id: proposta que mudou desde a leitura é
# `stale`; a que bate em regra do banco (nome de unidade repetido, membro já
# ativo) é `conflict`, num savepoint, sem derrubar as outras. Unidades antes de
# equipes antes de membros; no lote, as eSF/eAP (70/76) antes das eSB (71), que
# nascem ligadas à única eSF/eAP ativa da unidade; zero ou várias → nula, e o
# admin escolhe (Desvio 13, D7; DentalCare::AssociateTeam).
module Cnes
  module Apply
    ORDER = { "unit" => 0, "team" => 1, "member" => 2 }.freeze
    MAX = 500
    ID = /\A\h{24}\z/

    module_function

    def call(city:, proposal_ids:, by:)
      ids = Array(proposal_ids)
      valid = ids.any? && ids.size <= MAX && ids.all? { |id| id.is_a?(String) && id.match?(ID) }
      return Result.fail(:invalid_proposals) unless valid

      applied = 0
      skipped = []
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(hashtext('cnes_apply'))")
        current = Proposal.for(city)[:proposals].index_by { |p| p[:id] }
        chosen = ids.uniq.filter_map do |id|
          next current[id] if current.key?(id)

          skipped << { id: id, reason: "stale" }
          nil
        end
        chosen.sort_by { |p| [ ORDER.fetch(p[:kind]), oral_health_team?(p) ? 1 : 0 ] }.each do |proposal|
          ApplicationRecord.transaction(requires_new: true) { apply!(proposal) }
          applied += 1
        rescue ActiveRecord::RecordNotFound
          skipped << { id: proposal[:id], reason: "stale" }
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
          skipped << { id: proposal[:id], reason: "conflict" }
        end
        DomainEvents.publish("cnes.proposals_applied", user_id: by.id, count: applied) if applied.positive?
      end
      Result.ok(applied: applied, skipped: skipped)
    end

    def apply!(proposal)
      t = proposal[:target]
      today = Time.zone.today
      case [ proposal[:kind], proposal[:action] ]
      when %w[unit link] then HealthUnit.lock.find(t[:health_unit_id]).update!(cnes: t[:cnes])
      when %w[unit create] then HealthUnit.create!(name: t[:name], kind: "ubs", cnes: t[:cnes])
      when %w[team create]
        HealthTeam.create!(ine: t[:ine], kind: t[:kind], name: t[:name], health_unit_id: t[:health_unit_id],
                           associated_team_id: oral_health_team?(proposal) ? sole_primary_care_team_id(t[:health_unit_id]) : nil)
      when %w[team end] then HealthTeam.lock.find(t[:health_team_id]).update!(active: false)
      when %w[member create]
        HealthTeamMember.create!(professional_id: t[:professional_id], health_team_id: t[:health_team_id],
                                 cbo_code: t[:cbo_code], started_on: today)
      when %w[member end]
        member = HealthTeamMember.lock.find(t[:health_team_member_id])
        member.update!(ended_on: [ today, member.started_on ].max)
      else
        raise ArgumentError, "proposta desconhecida: #{proposal[:kind]}/#{proposal[:action]}"
      end
    end

    def oral_health_team?(proposal) = proposal[:kind] == "team" && proposal[:target][:kind] == DentalCare::Catalog::ORAL_HEALTH_TEAM_KIND

    def sole_primary_care_team_id(unit_id)
      ids = HealthTeam.where(health_unit_id: unit_id, active: true, kind: HealthTeam::PRIMARY_CARE_KINDS).limit(2).pluck(:id)
      ids.first if ids.size == 1
    end
  end
end
