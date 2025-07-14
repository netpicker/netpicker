from typing import cast

from netmiko import BaseConnection

from kopimiko import FileTransferInfo
from kopimiko.comm import ScrapeCommand
from kopimiko.platforms import PlatformHandler, TransferMethods


scraper = ScrapeCommand(
    command='show full-configuration',
)


def show_full_configuration(ch: BaseConnection, fti: FileTransferInfo):
    ch.send_command('config system global', ch.prompt_pattern)
    try:
        return scraper.transfer(ch, fti)
    finally:
        ch.send_command('end', ch.prompt_pattern)


class Fortinet(PlatformHandler):
    def transfer_methods(self, fti: FileTransferInfo) -> TransferMethods:
        return cast(TransferMethods, [show_full_configuration])