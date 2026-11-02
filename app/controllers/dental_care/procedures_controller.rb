# POST /dental/procedures/search { q } (ADR 0046; contrato §16 O5, O21;
# Ruling 6): procedimentos SIGTAP que a FAO aceita, com local, máximo, TSB/ASB
# e prótese. Termo só no corpo; sem dado pessoal e sem trilha. Quem tem vínculo
# ativo de papel odontológico (dentista ou TSB/ASB) ou o municipal_admin (tela
# da lista do TSB/ASB). Sem release: 503.
module DentalCare
  class ProceduresController < BaseController
    before_action { forbid unless admin? || Consultations::Authorization.allowed_links(user: Current.user, kind: "dental").any? }

    def search
      procedures = ProcedureSearch.call(body["q"])
      return render_error("terminology_unavailable", :service_unavailable) if procedures.nil?

      render json: { procedures: procedures }
    end
  end
end
