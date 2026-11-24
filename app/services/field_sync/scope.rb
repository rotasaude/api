# Escopo do download do app de campo (módulo 24b, ADR 0052; contrato §1, §9.3;
# 6A; Review Focus 4): as microáreas ATIVAS que o dono do aparelho baixa, nas
# equipes ativas 70/76 em que tem papel de campo — o ACS (515105) as em que é
# o responsável (24a), o outro CBO da Tabela 7 as atribuídas a ele
# (micro_area_field_assignments ativas). É o HomeVisits::Access.scope do envio
# (Task 20) e da sessão (as mesmas equipes e microáreas do GET /field/v1/session).
# Leitor (enfermeiro/médico) não tem aparelho: nunca entra.
#
# `digest` = SHA-256 dos ids ordenados, separados por vírgula: só ids de
# microárea, nunca dado pessoal. Mudou o conjunto (atribuição nova ou
# encerrada, ACS trocado, microárea desativada) → o digest muda → reset.
# Módulo 35a (W-14, Q6): com `vector_control:` utilizável, o texto do digest
# ganha ",vector_control"; ligar ou desligar o interruptor chega ao aparelho
# como reset: true (as linhas antigas do 35a vêm na carga nova). Módulo 35b
# (§11; plano, Review Focus 5): com `zoonoses:` (Zoonoses::Gate.field_usable?),
# o texto ganha ",zoonoses" depois; desligado, o digest é o da v1.3.0.
module FieldSync
  module Scope
    FIELD_KINDS = [ HomeVisits::Access::SCOPE_KINDS.fetch(:acs), HomeVisits::Access::SCOPE_KINDS.fetch(:field) ].freeze

    module_function

    VECTOR_MARK = ",vector_control".freeze
    ZOONOSES_MARK = ",zoonoses".freeze

    # -> { micro_area_ids: [uuid ordenados], digest: "<64 hex>" }
    def for(user, vector_control: false, zoonoses: false)
      ids = teams(user).flat_map do |team|
        scope = HomeVisits::Access.scope(user, team)
        FIELD_KINDS.include?(scope[:kind]) ? scope[:micro_area_ids] : []
      end
      ids = ids.empty? ? [] : MicroArea.where(id: ids, active: true).pluck(:id).sort
      { micro_area_ids: ids, digest: Digest::SHA256.hexdigest("#{ids.join(',')}#{VECTOR_MARK if vector_control}#{ZOONOSES_MARK if zoonoses}") }
    end

    def teams(user)
      return [] unless user&.professional

      team_ids = HealthTeamMember.active.where(professional: user.professional).pluck(:health_team_id)
      HealthTeam.where(id: team_ids, active: true, kind: TerritoryRegistry::Catalog::TEAM_KINDS).order(:id).to_a
    end
    private_class_method :teams
  end
end
