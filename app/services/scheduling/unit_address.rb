# Endereço da unidade na forma de reference_units (contratos §8):
# { street, number, complement, zip }. Fonte única: Territory::ReferenceUnits
# também monta o endereço por aqui.
module Scheduling
  module UnitAddress
    module_function

    def call(unit)
      return nil unless unit

      { street: unit.address_street, number: unit.address_number, complement: unit.address_complement,
        zip: unit.address_zip }
    end
  end
end
