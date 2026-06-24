import 'package:flutter/widgets.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

/// Persian labels for the phone-number type dropdown in the add/edit form.
const Map<PhoneLabel, String> kPhoneLabels = {
  PhoneLabel.mobile: 'موبایل',
  PhoneLabel.home: 'منزل',
  PhoneLabel.work: 'محل کار',
  PhoneLabel.other: 'سایر',
};

/// Persian labels for the email type dropdown in the add/edit form.
const Map<EmailLabel, String> kEmailLabels = {
  EmailLabel.home: 'شخصی',
  EmailLabel.work: 'محل کار',
  EmailLabel.other: 'سایر',
};

/// A single editable phone row in the add/edit contact form: owns its text
/// controller and the selected [label]. Dispose [controller] with the form.
class PhoneEntry {
  final TextEditingController controller;
  PhoneLabel label;
  PhoneEntry({String text = '', this.label = PhoneLabel.mobile})
    : controller = TextEditingController(text: text);
}

/// A single editable email row in the add/edit contact form.
class EmailEntry {
  final TextEditingController controller;
  EmailLabel label;
  EmailEntry({String text = '', this.label = EmailLabel.home})
    : controller = TextEditingController(text: text);
}
