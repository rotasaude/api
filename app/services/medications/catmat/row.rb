# Uma linha do CATMAT já lida (ver Client.build_row). Arquivo próprio para o
# Zeitwerk achar a constante em lazy load, sem depender de Client carregado.
module Medications
  module Catmat
    Row = Data.define(:catmat_code, :pdm_code, :pdm_name, :description, :updated_at)
  end
end
