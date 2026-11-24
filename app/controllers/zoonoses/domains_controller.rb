# /zoonoses/domains (módulo 35b, ADR 0054; contrato §10, §11; Q10, Q11):
# exatamente Zoonoses::Json.domains, o `zoonoses_domains` da referência do app
# mais as listas do dashboard. Para reader? e quem lê a visita domiciliar em
# alguma equipe (o agente de campo); os outros → 403 missing_role. Com o gate
# `zoonoses` desligado → 403 feature_disabled (Q10). Vocabulário da cidade, sem
# dado de pessoa: sem trilha.
module Zoonoses
  class DomainsController < BaseController
    def show
      user = Current.user
      return forbid unless Access.reader?(user) || HomeVisits::Access.reads_somewhere?(user)
      return unless query_only!

      render json: Json.domains
    end
  end
end
