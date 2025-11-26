from sys import stdin, stdout
from comms import recv_loop, send


def main():
    # input, output = os.fdopen(1, "rb"), os.fdopen(2, "wb")

    for message in recv_loop(stdin):
        print(message)

        send(message, stdout)  # echo the message back


if __name__ == "__main__":
    main()
