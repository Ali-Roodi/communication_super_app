import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../bloc/contact_bloc.dart';
import '../bloc/contact_event.dart';
import '../bloc/contact_state.dart';
import '../models/contact_model.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';

class AddEditContactScreen extends StatefulWidget {
  final String? contactId;

  const AddEditContactScreen({
    super.key,
    this.contactId,
  });

  @override
  State<AddEditContactScreen> createState() => _AddEditContactScreenState();
}

class _AddEditContactScreenState extends State<AddEditContactScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  ContactModel? _originalContact;

  @override
  void initState() {
    super.initState();
    if (widget.contactId != null) {
      context.read<ContactBloc>().add(GetContactById(widget.contactId!));
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  void _saveContact() {
    if (_formKey.currentState!.validate()) {
      final now = DateTime.now();
      final contact = ContactModel(
        id: widget.contactId ?? const Uuid().v4(),
        name: _nameController.text.trim(),
        phoneNumber: _phoneController.text.trim(),
        email: _emailController.text.trim().isEmpty
            ? null
            : _emailController.text.trim(),
        createdAt: _originalContact?.createdAt ?? now,
        updatedAt: now,
      );

      if (widget.contactId != null) {
        context.read<ContactBloc>().add(UpdateContact(contact));
      } else {
        context.read<ContactBloc>().add(CreateContact(contact));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ContactBloc, ContactState>(
      listener: (context, state) {
        if (state is ContactLoaded && widget.contactId != null) {
          _originalContact = state.contact;
          _nameController.text = state.contact.name;
          _phoneController.text = state.contact.phoneNumber;
          _emailController.text = state.contact.email ?? '';
        }

        if (state is ContactOperationSuccess) {
          Navigator.of(context).pop();
        }

        if (state is ContactError) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(state.message)),
          );
        }
      },
      child: Scaffold(
        appBar: RtlAppBar(
          title: widget.contactId != null ? 'Edit Contact' : 'Add Contact',
          actions: [
            TextButton(
              onPressed: _saveContact,
              child: const Text('Save'),
            ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  prefixIcon: Icon(Icons.person),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _phoneController,
                decoration: const InputDecoration(
                  labelText: 'Phone Number',
                  prefixIcon: Icon(Icons.phone),
                ),
                keyboardType: TextInputType.phone,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a phone number';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email (Optional)',
                  prefixIcon: Icon(Icons.email),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
            ],
          ),
        ),
      ),
    );
  }
}


