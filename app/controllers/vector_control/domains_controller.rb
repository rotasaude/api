# /vector_control/domains (módulo 35a, ADR 0054; contrato §13; Q8): os
# domínios do boletim e da ovitrampa, exatamente o `vector_control_domains` da
# referência do app (VectorControl::Json.domains, o mesmo serializador). Para
# os leitores do 35a (coordenação, vector_lab, municipal_admin) e, Q32, quem lê
# a visita domiciliar do 24b em alguma equipe (HomeVisits::Access.reads_somewhere?:
# ACS, Tabela 7 com o agente de endemias, enfermeiro, médico). São vocabulário
# da cidade: a regra é por usuário, não por equipe. Os outros → 403
# missing_role. Sem dado de pessoa: sem trilha.
module VectorControl
  class DomainsController < BaseController
    def show
      user = Current.user
      return forbid unless Access.reader?(user) || HomeVisits::Access.reads_somewhere?(user)
      return unless query_only!

      render json: Json.domains
    end
  end
end
