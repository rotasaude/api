# Identificação que as fichas da escuta exigem (ADR 0030; spec §5), já
# conferida por Ledi::ScreeningFicha. Valores, não registros: a ficha é pura.
# citizen_cns (módulo 24a): só para o paciente sem CPF — CPF e CNS nunca vão
# juntos na ficha; a escuta passa nil (o par sempre tem CPF).
module Ledi
  module Fichas
    ScreeningIdentity = Data.define(:cnes, :ine, :professional_cns, :cbo, :citizen_cpf, :citizen_cns, :birth_date, :sex,
                                    :started_at, :ended_at, :ibge_code)
  end
end
