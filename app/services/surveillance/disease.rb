# Doença da lista da cidade (módulo 25; contrato §2 `<disease>`): da versão da
# plataforma em vigor ou local. `id` e `active` são da local (nil na da
# plataforma); `list_version` é da plataforma (nil na local). Só referência
# de catálogo, sem dado de paciente.
module Surveillance
  Disease = Data.define(:code, :name, :deadline, :cid10, :ciap2, :repeat_after_days, :sinan_form, :local, :list_version,
                        :notes, :id, :active) do
    def to_json_hash
      { code: code, name: name, deadline: deadline, cid10: cid10, ciap2: ciap2, repeat_after_days: repeat_after_days,
        sinan_form: sinan_form, local: local, list_version: list_version, notes: notes, id: id, active: active }
    end
  end
end
