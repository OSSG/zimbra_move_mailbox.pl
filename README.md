# zimbra_move_mailbox.pl
A custom tool to relocate Zimbra mailboxes between stores

## Brief info
At the moment `zmmailbox` tool is not available in the open source edition of Zimbra Collaboration Suite. This tool could be used for relocation of mailboxes between Zimbra mail stores with respect to identities, signatures, CoS and account properties.

The basic idea comes from [this nice project](https://github.com/nfetisov/movembox), but the given tool is much more complicated and could be used even for relocation of big mailboxes.

## Configuration
Configuration sits in `Constants.pm` module which should be located in the same directory as the tool itself. `Contants.pm.example` could be used as a template.

## Usage

### Basic usage

    movembox.pl --acc <account to move> --dest <zimbra mail store> [--temp <temporary directory>] [--[v]verbose] [--dry-run] [--skip-emails]


Default values:
- temp: `/tmp/movembox`
- verbose: `false`
- vverbose: `false`
- dry-run: `false`
- skip-emails: `false`

## Important note
Zimbra proved to be very, hmmm, _unpredictable_ when relocating mailboxes, since actual process involves creation of a new account at the destination mail store and then moving mailbox contents via standard backup/restore mechanism. Sometimes backups could be restored without any errors, but with some emails missed. Especially when talking about huge mailboxes (several GBs and more).

This tool doesn't delete old account, after relocation it just will be renamed with `old-` prefix, so it will be possible to revert all changes. The only tricky thing here is that "old" account will be automatically closed during relocation. If something will go wrong one will have to delete the "new" account, rename the "old" account, change the state of the account in question to the original state, and restore the membership of the account in all distribution lists.

That's why it's recommended to use the tool in very verbose mode: more info could be useful sometimes.

### Examples

#### 1. Relocate a mailbox in normal (silent) mode when only warnings and errors are written to STDERR:

    movembox.pl --acc test@example.com --dest zm-store-N.example.com


#### 2. Relocate a mailbox in verbose mode (with info messages written to STDOUT) and a custom temporary directory:

    movembox.pl --acc test@example.com --dest zm-store-N.example.com --verbose --temp /opt/zimbra/movembox/temp/


#### 3. Relocate a mailbox in very verbose mode (with info and debug messages written to STDOUT and a dump of account data structure written to a special file in the temporary dir) and a custom temporary directory:

    movembox.pl --acc test@example.com --dest zm-store-N.example.com --vverbose --temp /opt/zimbra/movembox/temp/


#### 4. Test possibility to relocate a mailbox (dry run mode) with a dump of account data structure written to a special file in the temporary dir:

    movembox.pl --acc test@example.com --dest zm-store-N.example.com --dry-run


#### 5. Relocate account without import of emails (could be useful for relocation of very large mailboxes, when backup archive should be preliminary split to several chunks):

    movembox.pl --acc test@example.com --dest zm-store-N.example.com --skip-emails

