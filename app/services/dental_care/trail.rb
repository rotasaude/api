# Trilha da leitura nominal da saúde bucal (Desvio 15): um clinical_record.viewed
# por paciente mostrado, com `access_scope: "dental"`. Só ids, o acesso e o
# código do motivo — nunca dente, situação ou procedimento.
module DentalCare
  module Trail
    module_function

    def viewed!(patient:, user:, grant:)
      ClinicalRecord::Trail.viewed!(patient: patient, user: user, grant: grant, extra: { access_scope: Catalog::TRAIL_SCOPE })
    end
  end
end
